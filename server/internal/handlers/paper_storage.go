package handlers

import (
	"errors"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"

	"github.com/gin-gonic/gin"

	"shenliyuan/internal/services"
)

type paperStorageReceiptSigner interface {
	SignReceipt(services.ExamPaperUploadReceipt) (string, error)
}

// PaperStorageHandler 提供独立试卷文件服务器的 HTTP 边界。
type PaperStorageHandler struct {
	files                 *services.ExamPaperFileService
	grantSigner           *services.ExamPaperStorageSigner
	receiptSigner         paperStorageReceiptSigner
	now                   func() time.Time
	diskUsage             func(string) (float64, error)
	validations           chan struct{}
	storePending          func(string, io.Reader) (*services.StoredExamPaperFile, error)
	statFile              func(string) (os.FileInfo, error)
	beginUploadSession    func(string, string, int64, time.Time, time.Time) (services.ExamPaperUploadSessionBeginResult, error)
	completeUploadSession func(string, string, string, services.StoredExamPaperFile, time.Time) error
	abortUploadSession    func(string, string) error
}

// NewPaperStorageHandler 创建独立文件服务处理器。
func NewPaperStorageHandler(files *services.ExamPaperFileService, grantSigner, receiptSigner *services.ExamPaperStorageSigner, maxConcurrentValidations int) *PaperStorageHandler {
	if maxConcurrentValidations <= 0 {
		maxConcurrentValidations = 1
	}
	handler := &PaperStorageHandler{
		files: files, grantSigner: grantSigner, receiptSigner: receiptSigner,
		now: time.Now, diskUsage: services.ExamPaperDiskUsagePercent,
		validations: make(chan struct{}, maxConcurrentValidations),
	}
	if files != nil {
		handler.storePending = files.StorePendingUploadReader
		handler.statFile = files.Stat
		handler.beginUploadSession = files.BeginUploadSession
		handler.completeUploadSession = files.CompleteUploadSession
		handler.abortUploadSession = files.AbortUploadSession
	}
	return handler
}

// RegisterPaperStorageRoutes 注册独立文件服务器全部路由。
func RegisterPaperStorageRoutes(router gin.IRouter, handler *PaperStorageHandler) {
	router.GET("/healthz", handler.Health)
	router.POST("/v1/uploads/:session_id", handler.Upload)
	router.GET("/v1/files/:file_key", handler.Download)
	router.POST("/internal/v1/files/:file_key/claim", handler.Claim)
	router.POST("/internal/v1/files/:file_key/trash", handler.Trash)
	router.GET("/internal/v1/files/:file_key/meta", handler.Metadata)
	router.POST("/internal/v1/maintenance", handler.Maintenance)
}

func (h *PaperStorageHandler) authorize(c *gin.Context, purpose string) (services.ExamPaperStorageGrant, bool) {
	authorization := strings.TrimSpace(c.GetHeader("Authorization"))
	if !strings.HasPrefix(authorization, "Bearer ") || strings.TrimSpace(strings.TrimPrefix(authorization, "Bearer ")) == "" {
		c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "unauthorized"})
		return services.ExamPaperStorageGrant{}, false
	}
	grant, err := h.grantSigner.VerifyGrant(strings.TrimSpace(strings.TrimPrefix(authorization, "Bearer ")), purpose, c.Request.Method, c.Request.URL.Path)
	if err != nil {
		c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "unauthorized"})
		return services.ExamPaperStorageGrant{}, false
	}
	return grant, true
}

func (h *PaperStorageHandler) authorizeFile(c *gin.Context, purpose, fileKey string) (services.ExamPaperStorageGrant, bool) {
	grant, ok := h.authorize(c, purpose)
	if !ok {
		return services.ExamPaperStorageGrant{}, false
	}
	if grant.FileKey != fileKey {
		c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "unauthorized"})
		return services.ExamPaperStorageGrant{}, false
	}
	return grant, true
}

// Health 返回磁盘健康等级。
func (h *PaperStorageHandler) Health(c *gin.Context) {
	usage, err := h.diskUsage(h.files.RootDir())
	if err != nil {
		c.JSON(http.StatusServiceUnavailable, gin.H{"status": "unknown"})
		return
	}
	status := "ok"
	if usage >= 95 {
		status = "readonly"
	} else if usage >= 70 {
		status = "warning"
	}
	c.JSON(http.StatusOK, gin.H{"status": status, "disk_usage_percent": usage})
}

// Upload 流式接收并校验单个 PDF 文件。
func (h *PaperStorageHandler) Upload(c *gin.Context) {
	sessionID := c.Param("session_id")
	grant, ok := h.authorize(c, services.ExamPaperStoragePurposeUpload)
	if !ok {
		return
	}
	if grant.SessionID != sessionID {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "unauthorized"})
		return
	}
	begin, err := h.beginUploadSession(sessionID, grant.JTI, grant.ExpectedSize, time.Unix(grant.ExpiresAt, 0), h.now())
	if err != nil {
		h.writeUploadSessionError(c, err)
		return
	}
	if begin.Completed {
		c.JSON(http.StatusCreated, gin.H{"receipt": begin.Receipt})
		return
	}
	completed := false
	defer func() {
		if !completed {
			_ = h.abortUploadSession(sessionID, grant.JTI)
		}
	}()
	usage, err := h.diskUsage(h.files.RootDir())
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "storage unavailable"})
		return
	}
	if usage >= 85 {
		c.JSON(http.StatusInsufficientStorage, gin.H{"error": "insufficient storage"})
		return
	}

	c.Request.Body = http.MaxBytesReader(c.Writer, c.Request.Body, services.ExamPaperMaxRequestBodySize)
	reader, err := c.Request.MultipartReader()
	if err != nil {
		h.writeMultipartError(c, err)
		return
	}
	var stored *services.StoredExamPaperFile
	for {
		part, nextErr := reader.NextPart()
		if errors.Is(nextErr, io.EOF) {
			break
		}
		if nextErr != nil {
			if stored != nil {
				_ = h.files.DiscardPending(stored.FileKey)
			}
			h.writeMultipartError(c, nextErr)
			return
		}
		if part.FormName() != "file" || part.FileName() == "" || stored != nil {
			_, _ = io.Copy(io.Discard, part)
			_ = part.Close()
			continue
		}
		defer part.Close()
		stored, err = h.storePendingWithSlot(c, part.FileName(), part)
		if err != nil {
			h.writeUploadError(c, err)
			return
		}
	}
	if stored == nil {
		c.JSON(http.StatusUnprocessableEntity, gin.H{"error": "invalid pdf"})
		return
	}
	if stored.Size != grant.ExpectedSize {
		_ = h.files.DiscardPending(stored.FileKey)
		c.JSON(http.StatusUnprocessableEntity, gin.H{"error": "file_size_mismatch"})
		return
	}
	receipt, err := h.receiptSigner.SignReceipt(services.ExamPaperUploadReceipt{
		SessionID: sessionID, FileKey: stored.FileKey, FileSize: stored.Size,
		SHA256: stored.SHA256, IssuedAt: h.now().Unix(),
	})
	if err != nil {
		_ = h.files.DiscardPending(stored.FileKey)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "storage unavailable"})
		return
	}
	if err := h.completeUploadSession(sessionID, grant.JTI, receipt, *stored, h.now()); err != nil {
		_ = h.files.DiscardPending(stored.FileKey)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "storage unavailable"})
		return
	}
	completed = true
	c.JSON(http.StatusCreated, gin.H{"receipt": receipt})
}

func (h *PaperStorageHandler) writeUploadSessionError(c *gin.Context, err error) {
	switch {
	case errors.Is(err, services.ErrExamPaperUploadInProgress):
		c.JSON(http.StatusConflict, gin.H{"error": "upload_session_in_progress"})
	case errors.Is(err, services.ErrExamPaperUploadSessionConsumed):
		c.JSON(http.StatusConflict, gin.H{"error": "upload_session_invalid"})
	case errors.Is(err, services.ErrExamPaperUploadSessionInvalid):
		c.JSON(http.StatusBadRequest, gin.H{"error": "upload_session_invalid"})
	default:
		c.JSON(http.StatusInternalServerError, gin.H{"error": "storage unavailable"})
	}
}

func (h *PaperStorageHandler) storePendingWithSlot(c *gin.Context, filename string, source io.Reader) (stored *services.StoredExamPaperFile, err error) {
	select {
	case h.validations <- struct{}{}:
	case <-c.Request.Context().Done():
		return nil, c.Request.Context().Err()
	}
	defer func() {
		<-h.validations
		if recovered := recover(); recovered != nil {
			panic(recovered)
		}
	}()
	return h.storePending(filename, source)
}

func (h *PaperStorageHandler) writeUploadError(c *gin.Context, err error) {
	var maxBytesErr *http.MaxBytesError
	switch {
	case errors.Is(err, services.ErrExamPaperFileTooLarge), errors.As(err, &maxBytesErr):
		c.JSON(http.StatusRequestEntityTooLarge, gin.H{"error": "file too large"})
	case errors.Is(err, services.ErrInvalidPDF), errors.Is(err, services.ErrEncryptedPDF):
		c.JSON(http.StatusUnprocessableEntity, gin.H{"error": "invalid pdf"})
	default:
		c.JSON(http.StatusInternalServerError, gin.H{"error": "storage unavailable"})
	}
}

func (h *PaperStorageHandler) writeMultipartError(c *gin.Context, err error) {
	var maxBytesErr *http.MaxBytesError
	if errors.As(err, &maxBytesErr) || errors.Is(err, multipart.ErrMessageTooLarge) {
		c.JSON(http.StatusRequestEntityTooLarge, gin.H{"error": "file too large"})
		return
	}
	c.JSON(http.StatusBadRequest, gin.H{"error": "invalid multipart request"})
}

// Download 验证用途后交由 Nginx 内部位置返回文件。
func (h *PaperStorageHandler) Download(c *gin.Context) {
	fileKey := c.Param("file_key")
	grant, previewOK := h.authorizeFileWithoutResponse(c, services.ExamPaperStoragePurposePreview, fileKey)
	disposition := "inline"
	if !previewOK {
		grant, previewOK = h.authorizeFileWithoutResponse(c, services.ExamPaperStoragePurposeDownload, fileKey)
		disposition = "attachment"
	}
	if !previewOK || grant.FileKey != fileKey {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "unauthorized"})
		return
	}
	info, err := h.statFile(fileKey)
	if err != nil || info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
		if os.IsNotExist(err) || errors.Is(err, services.ErrInvalidExamPaperFileKey) {
			c.JSON(http.StatusNotFound, gin.H{"error": "not found"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "storage unavailable"})
		return
	}
	c.Header("Content-Disposition", fmt.Sprintf(`%s; filename="%s"`, disposition, fileKey))
	c.Header("Cache-Control", "private, no-store")
	c.Header("X-Accel-Redirect", "/_paper_files/"+url.PathEscape(fileKey))
	c.Status(http.StatusOK)
}

func (h *PaperStorageHandler) authorizeFileWithoutResponse(c *gin.Context, purpose, fileKey string) (services.ExamPaperStorageGrant, bool) {
	authorization := strings.TrimSpace(c.GetHeader("Authorization"))
	if !strings.HasPrefix(authorization, "Bearer ") {
		return services.ExamPaperStorageGrant{}, false
	}
	grant, err := h.grantSigner.VerifyGrant(strings.TrimSpace(strings.TrimPrefix(authorization, "Bearer ")), purpose, c.Request.Method, c.Request.URL.Path)
	return grant, err == nil && grant.FileKey == fileKey
}

// Claim 幂等认领文件。
func (h *PaperStorageHandler) Claim(c *gin.Context) {
	fileKey := c.Param("file_key")
	if _, ok := h.authorizeFile(c, services.ExamPaperStoragePurposeClaim, fileKey); !ok {
		return
	}
	if err := h.files.Claim(fileKey); err != nil {
		h.writeFileError(c, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"status": "ok"})
}

// Trash 幂等将文件移入回收站。
func (h *PaperStorageHandler) Trash(c *gin.Context) {
	fileKey := c.Param("file_key")
	if _, ok := h.authorizeFile(c, services.ExamPaperStoragePurposeDelete, fileKey); !ok {
		return
	}
	if err := h.files.Trash(fileKey); err != nil {
		h.writeFileError(c, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"status": "ok"})
}

// Metadata 返回文件当前元数据。
func (h *PaperStorageHandler) Metadata(c *gin.Context) {
	fileKey := c.Param("file_key")
	if _, ok := h.authorizeFile(c, services.ExamPaperStoragePurposeMetadata, fileKey); !ok {
		return
	}
	metadata, err := h.files.Metadata(fileKey)
	if err != nil {
		h.writeFileError(c, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"file_key": metadata.FileKey, "size": metadata.Size, "sha256": metadata.SHA256})
}

func (h *PaperStorageHandler) writeFileError(c *gin.Context, err error) {
	if os.IsNotExist(err) || errors.Is(err, services.ErrInvalidExamPaperFileKey) {
		c.JSON(http.StatusNotFound, gin.H{"error": "not found"})
		return
	}
	c.JSON(http.StatusInternalServerError, gin.H{"error": "storage unavailable"})
}

// Maintenance 清理过期内容并返回磁盘使用率。
func (h *PaperStorageHandler) Maintenance(c *gin.Context) {
	if _, ok := h.authorize(c, services.ExamPaperStoragePurposeMaintenance); !ok {
		return
	}
	result, err := h.files.Maintenance(h.now())
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "maintenance failed"})
		return
	}
	usage, err := h.diskUsage(h.files.RootDir())
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "storage unavailable"})
		return
	}
	c.JSON(http.StatusOK, gin.H{
		"unclaimed_files_removed":           result.UnclaimedFilesRemoved,
		"pending_markers_removed":           result.PendingMarkersRemoved,
		"trash_files_removed":               result.TrashFilesRemoved,
		"temporary_files_removed":           result.TemporaryFilesRemoved,
		"stale_upload_sessions_removed":     result.StaleUploadSessionsRemoved,
		"completed_upload_sessions_removed": result.CompletedUploadSessionsRemoved,
		"disk_usage_percent":                usage,
	})
}
