package handlers

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"mime"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"

	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

const (
	defaultExamPaperPageSize                 = 20
	maxExamPaperPageSize                     = 50
	maxExamPaperUploadsPerWindow             = 3
	examPaperRewardExp                       = 10
	examPaperUploadRateWindow                = time.Minute
	examPaperStorageModeLocal                = "local"
	examPaperStorageModeRemote               = "remote"
	examPaperStorageModeReadonlyRemote       = "readonly-remote"
	maxExamPaperJSONBodyBytes          int64 = 64 * 1024
	examPaperFileGrantTTL                    = 2 * time.Minute
)

type examPaperRemoteFileURLSigner interface {
	SignedFileURL(models.ExamPaper, string, time.Duration) (string, error)
}

// ExamPaperHandler 提供试卷投稿、浏览、下载与审核接口。
type ExamPaperHandler struct {
	db               *gorm.DB
	files            *services.ExamPaperFileService
	uploads          *services.ExamPaperUploadService
	storageMode      string
	storageBaseURL   string
	remoteFiles      examPaperRemoteFileURLSigner
	storageJobs      *services.ExamPaperStorageJobService
	uploadLimiter    *examPaperUploadLimiter
	purgeLocalDelete func(services.ExamPaperTrashMove) error
}

// NewExamPaperHandler 创建试卷处理器。
func NewExamPaperHandler(db *gorm.DB, files *services.ExamPaperFileService) *ExamPaperHandler {
	handler := &ExamPaperHandler{db: db, files: files, storageMode: examPaperStorageModeLocal, uploadLimiter: newExamPaperUploadLimiter()}
	if files != nil {
		handler.purgeLocalDelete = files.PurgeDelete
	}
	return handler
}

// NewExamPaperHandlerWithStorage 创建支持远端上传会话的试卷处理器。
func NewExamPaperHandlerWithStorage(db *gorm.DB, files *services.ExamPaperFileService, mode, baseURL string, uploads *services.ExamPaperUploadService, dependencies ...any) *ExamPaperHandler {
	handler := NewExamPaperHandler(db, files)
	handler.storageMode = strings.TrimSpace(mode)
	handler.storageBaseURL = strings.TrimRight(strings.TrimSpace(baseURL), "/")
	handler.uploads = uploads
	for _, dependency := range dependencies {
		switch value := dependency.(type) {
		case examPaperRemoteFileURLSigner:
			handler.remoteFiles = value
		case *services.ExamPaperStorageJobService:
			handler.storageJobs = value
		}
	}
	return handler
}

type examPaperUploadLimiter struct {
	mu   sync.Mutex
	hits map[uint][]time.Time
}

func newExamPaperUploadLimiter() *examPaperUploadLimiter {
	return &examPaperUploadLimiter{hits: make(map[uint][]time.Time)}
}

func (l *examPaperUploadLimiter) allow(userID uint, now time.Time) bool {
	windowStart := now.Add(-examPaperUploadRateWindow)
	l.mu.Lock()
	defer l.mu.Unlock()

	recent := l.hits[userID][:0]
	for _, hit := range l.hits[userID] {
		if hit.After(windowStart) {
			recent = append(recent, hit)
		}
	}
	if len(recent) >= maxExamPaperUploadsPerWindow {
		l.hits[userID] = recent
		return false
	}
	recent = append(recent, now)
	l.hits[userID] = recent
	return true
}

type examPaperContributorResponse struct {
	ID       uint   `json:"id"`
	Avatar   string `json:"avatar"`
	Nickname string `json:"nickname"`
	Level    int    `json:"level"`
}

type examPaperResponse struct {
	ID              uint                         `json:"id"`
	Status          models.ExamPaperStatus       `json:"status"`
	Source          models.ExamPaperSource       `json:"source"`
	CourseName      string                       `json:"course_name"`
	AcademicYear    string                       `json:"academic_year"`
	Semester        models.ExamPaperSemester     `json:"semester"`
	ExamType        models.ExamPaperType         `json:"exam_type"`
	Title           string                       `json:"title"`
	FileSize        int64                        `json:"file_size"`
	DownloadCount   int64                        `json:"download_count"`
	ApprovalReason  string                       `json:"approval_reason,omitempty"`
	UnpublishReason string                       `json:"unpublish_reason,omitempty"`
	PublishedAt     *time.Time                   `json:"published_at,omitempty"`
	UnpublishedAt   *time.Time                   `json:"unpublished_at,omitempty"`
	RewardRevocable bool                         `json:"reward_revocable"`
	CreatedAt       time.Time                    `json:"created_at"`
	Contributor     examPaperContributorResponse `json:"contributor"`
}

type examPaperListResponse struct {
	Items         []examPaperResponse `json:"items"`
	Page          int                 `json:"page"`
	PageSize      int                 `json:"page_size"`
	Total         int64               `json:"total"`
	AcademicYears []string            `json:"academic_years"`
	StatusCounts  map[string]int64    `json:"status_counts,omitempty"`
}

func examPaperToResponse(paper models.ExamPaper) examPaperResponse {
	return examPaperResponse{
		ID:              paper.ID,
		Status:          paper.Status,
		Source:          paper.Source,
		CourseName:      paper.CourseName,
		AcademicYear:    paper.AcademicYear,
		Semester:        paper.Semester,
		ExamType:        paper.ExamType,
		Title:           paper.Title,
		FileSize:        paper.FileSize,
		DownloadCount:   paper.DownloadCount,
		ApprovalReason:  paper.ApprovalReason,
		UnpublishReason: paper.UnpublishReason,
		PublishedAt:     paper.PublishedAt,
		UnpublishedAt:   paper.UnpublishedAt,
		RewardRevocable: paper.RewardedAt != nil && paper.RewardRevokedAt == nil,
		CreatedAt:       paper.CreatedAt,
		Contributor: examPaperContributorResponse{
			ID:       paper.Submitter.ID,
			Avatar:   paper.Submitter.Avatar,
			Nickname: paper.Submitter.Nickname,
			Level:    services.CalculateUserLevel(paper.Submitter.Exp),
		},
	}
}

// revokeExamPaperReward 在当前事务内撤销尚未撤销的试卷投稿奖励。
func revokeExamPaperReward(tx *gorm.DB, paper *models.ExamPaper, now time.Time) (bool, error) {
	paperResult := tx.Model(&models.ExamPaper{}).
		Where("id = ? AND rewarded_at IS NOT NULL AND reward_revoked_at IS NULL", paper.ID).
		UpdateColumn("reward_revoked_at", now)
	if paperResult.Error != nil {
		return false, paperResult.Error
	}
	if paperResult.RowsAffected == 0 {
		return false, nil
	}
	if paperResult.RowsAffected != 1 {
		return false, fmt.Errorf("撤销试卷奖励失败：更新了 %d 条试卷记录", paperResult.RowsAffected)
	}

	userResult := tx.Model(&models.User{}).Where("id = ?", paper.SubmitterID).UpdateColumn(
		"exp",
		gorm.Expr("CASE WHEN exp >= ? THEN exp - ? ELSE 0 END", examPaperRewardExp, examPaperRewardExp),
	)
	if userResult.Error != nil {
		return false, userResult.Error
	}
	if userResult.RowsAffected != 1 {
		return false, fmt.Errorf("撤销试卷奖励失败：投稿人不存在")
	}

	paper.RewardRevokedAt = &now
	return true, nil
}

func writeExamPaperError(c *gin.Context, status int, code, message string) {
	c.JSON(status, gin.H{"error": message, "code": code})
}

func parseExamPaperID(c *gin.Context) (uint, bool) {
	value, err := strconv.ParseUint(c.Param("id"), 10, 64)
	if err != nil || value == 0 {
		writeExamPaperError(c, http.StatusNotFound, "exam_paper_not_found", "试卷不存在")
		return 0, false
	}
	return uint(value), true
}

func (h *ExamPaperHandler) currentExamPaperUser(c *gin.Context) (models.User, bool) {
	value, ok := c.Get("user_id")
	if !ok {
		writeExamPaperError(c, http.StatusUnauthorized, "authentication_required", "请先登录")
		return models.User{}, false
	}
	userID, ok := value.(uint)
	if !ok || userID == 0 {
		writeExamPaperError(c, http.StatusUnauthorized, "authentication_required", "登录状态无效")
		return models.User{}, false
	}
	var user models.User
	if err := h.db.Select("id", "role", "edu_bound", "nickname", "avatar", "exp").First(&user, userID).Error; err != nil {
		writeExamPaperError(c, http.StatusUnauthorized, "authentication_required", "登录用户不存在")
		return models.User{}, false
	}
	if !isExamPaperAdmin(user) && !user.EduBound {
		writeExamPaperError(c, http.StatusForbidden, "edu_verification_required", "完成教务认证后才能使用试卷库")
		return models.User{}, false
	}
	return user, true
}

func isExamPaperAdmin(user models.User) bool {
	return user.Role == models.RoleAdmin || user.Role == models.RoleSuperAdmin
}

func parseExamPaperPositiveInt(raw string, defaultValue int) int {
	value, err := strconv.Atoi(raw)
	if err != nil || value <= 0 {
		return defaultValue
	}
	return value
}

// List 返回已发布试卷的分页列表。
func (h *ExamPaperHandler) List(c *gin.Context) {
	if _, ok := h.currentExamPaperUser(c); !ok {
		return
	}
	page := parseExamPaperPositiveInt(c.Query("page"), 1)
	pageSize := parseExamPaperPositiveInt(c.Query("page_size"), defaultExamPaperPageSize)
	if pageSize > maxExamPaperPageSize {
		pageSize = maxExamPaperPageSize
	}

	var academicYears []string
	if err := h.db.Model(&models.ExamPaper{}).
		Where("status = ?", models.ExamPaperStatusPublished).
		Distinct("academic_year").
		Order("academic_year DESC").
		Pluck("academic_year", &academicYears).Error; err != nil {
		writeExamPaperError(c, http.StatusInternalServerError, "internal_error", "获取试卷学年失败")
		return
	}

	query := h.db.Model(&models.ExamPaper{}).Where("status = ?", models.ExamPaperStatusPublished)
	if keyword := strings.TrimSpace(c.Query("keyword")); keyword != "" {
		query = query.Where("LOWER(course_name) LIKE ?", "%"+strings.ToLower(keyword)+"%")
	}
	if academicYear := strings.TrimSpace(c.Query("academic_year")); academicYear != "" {
		query = query.Where("academic_year = ?", academicYear)
	}
	if semester := strings.TrimSpace(c.Query("semester")); semester != "" {
		query = query.Where("semester = ?", semester)
	}
	if examType := strings.TrimSpace(c.Query("exam_type")); examType != "" {
		query = query.Where("exam_type = ?", examType)
	}
	var total int64
	if err := query.Count(&total).Error; err != nil {
		writeExamPaperError(c, http.StatusInternalServerError, "internal_error", "获取试卷列表失败")
		return
	}
	var papers []models.ExamPaper
	order := "published_at DESC, id DESC"
	if c.Query("sort") == "downloads" {
		order = "download_count DESC, published_at DESC, id DESC"
	}
	if err := query.Preload("Submitter").
		Order(order).
		Limit(pageSize).
		Offset((page - 1) * pageSize).
		Find(&papers).Error; err != nil {
		writeExamPaperError(c, http.StatusInternalServerError, "internal_error", "获取试卷列表失败")
		return
	}
	items := make([]examPaperResponse, 0, len(papers))
	for _, paper := range papers {
		items = append(items, examPaperToResponse(paper))
	}
	c.JSON(http.StatusOK, examPaperListResponse{
		Items:         items,
		Page:          page,
		PageSize:      pageSize,
		Total:         total,
		AcademicYears: academicYears,
	})
}

// Get 仅返回已发布试卷详情。
func (h *ExamPaperHandler) Get(c *gin.Context) {
	if _, ok := h.currentExamPaperUser(c); !ok {
		return
	}
	id, ok := parseExamPaperID(c)
	if !ok {
		return
	}
	var paper models.ExamPaper
	if err := h.db.Preload("Submitter").
		Where("id = ? AND status = ?", id, models.ExamPaperStatusPublished).
		First(&paper).Error; err != nil {
		writeExamPaperError(c, http.StatusNotFound, "exam_paper_not_found", "\u8bd5\u5377\u4e0d\u5b58\u5728")
		return
	}
	c.JSON(http.StatusOK, examPaperToResponse(paper))
}

// MySubmissions 分页返回当前用户的全部投稿，并支持按状态筛选。
func (h *ExamPaperHandler) MySubmissions(c *gin.Context) {
	user, ok := h.currentExamPaperUser(c)
	if !ok {
		return
	}
	page := parseExamPaperPositiveInt(c.Query("page"), 1)
	pageSize := parseExamPaperPositiveInt(c.Query("page_size"), defaultExamPaperPageSize)
	if pageSize > maxExamPaperPageSize {
		pageSize = maxExamPaperPageSize
	}
	statuses := []models.ExamPaperStatus{
		models.ExamPaperStatusPending,
		models.ExamPaperStatusPublished,
		models.ExamPaperStatusUnpublished,
	}
	status := strings.TrimSpace(c.Query("status"))
	if status != "" && status != "all" && status != string(models.ExamPaperStatusPending) && status != string(models.ExamPaperStatusPublished) && status != string(models.ExamPaperStatusUnpublished) {
		writeExamPaperError(c, http.StatusBadRequest, "invalid_exam_paper_status", "投稿状态无效")
		return
	}

	counts := make(map[string]int64, 4)
	counts["all"] = 0
	countRows := make([]struct {
		Status models.ExamPaperStatus
		Count  int64
	}, 0, len(statuses))
	if err := h.db.Model(&models.ExamPaper{}).
		Select("status, COUNT(*) AS count").
		Where("submitter_id = ? AND status IN ?", user.ID, statuses).
		Group("status").Scan(&countRows).Error; err != nil {
		writeExamPaperError(c, http.StatusInternalServerError, "internal_error", "获取我的投稿失败")
		return
	}
	for _, item := range statuses {
		counts[string(item)] = 0
	}
	for _, row := range countRows {
		counts[string(row.Status)] = row.Count
		counts["all"] += row.Count
	}

	queryStatuses := statuses
	if status == "" {
		// 未升级客户端没有状态分段，继续只返回待审核和已发布，避免点击已下架条目后进入无权限详情。
		queryStatuses = []models.ExamPaperStatus{
			models.ExamPaperStatusPending,
			models.ExamPaperStatusPublished,
		}
	}
	query := h.db.Model(&models.ExamPaper{}).Where("submitter_id = ? AND status IN ?", user.ID, queryStatuses)
	if status != "" && status != "all" {
		query = query.Where("status = ?", status)
	}
	var total int64
	if err := query.Count(&total).Error; err != nil {
		writeExamPaperError(c, http.StatusInternalServerError, "internal_error", "\u83b7\u53d6\u6211\u7684\u6295\u7a3f\u5931\u8d25")
		return
	}
	var papers []models.ExamPaper
	if err := query.Preload("Submitter").Order("created_at DESC, id DESC").
		Limit(pageSize).Offset((page - 1) * pageSize).Find(&papers).Error; err != nil {
		writeExamPaperError(c, http.StatusInternalServerError, "internal_error", "\u83b7\u53d6\u6211\u7684\u6295\u7a3f\u5931\u8d25")
		return
	}
	items := make([]examPaperResponse, 0, len(papers))
	for _, paper := range papers {
		items = append(items, examPaperToResponse(paper))
	}
	c.JSON(http.StatusOK, examPaperListResponse{Items: items, Page: page, PageSize: pageSize, Total: total, StatusCounts: counts})
}

// Upload 接收 PDF 投稿；管理员从同一入口上传时直接发布。
func (h *ExamPaperHandler) Upload(c *gin.Context) {
	user, ok := h.currentExamPaperUser(c)
	if !ok {
		return
	}
	if h.storageMode == examPaperStorageModeRemote {
		writeExamPaperError(c, http.StatusUpgradeRequired, "client_upgrade_required", "请升级客户端后上传试卷")
		return
	}
	if h.storageMode == examPaperStorageModeReadonlyRemote {
		writeExamPaperError(c, http.StatusServiceUnavailable, "storage_unavailable", "试卷上传暂不可用")
		return
	}
	if !isExamPaperAdmin(user) && !h.ensureExamPaperUploadAllowed(c, user) {
		return
	}

	formValues, stored, err := h.readExamPaperUpload(c)
	if err != nil {
		if stored != nil {
			_ = h.files.Remove(stored.FileKey)
		}
		h.writeFileValidationError(c, err)
		return
	}
	keepStoredFile := false
	defer func() {
		if !keepStoredFile {
			_ = h.files.Remove(stored.FileKey)
		}
	}()

	if !strings.EqualFold(strings.TrimSpace(formValues["privacy_confirmed"]), "true") {
		writeExamPaperError(c, http.StatusBadRequest, "privacy_confirmation_required", "请确认文件不含隐私信息且拥有分享权限")
		return
	}

	metadata, err := models.NormalizeExamPaperMetadata(
		formValues["course_name"],
		formValues["academic_year"],
		models.ExamPaperSemester(formValues["semester"]),
		models.ExamPaperType(formValues["exam_type"]),
	)
	if err != nil {
		writeExamPaperError(c, http.StatusBadRequest, "invalid_exam_paper_metadata", err.Error())
		return
	}

	now := time.Now()
	paper := models.ExamPaper{
		Status:       models.ExamPaperStatusPending,
		Source:       models.ExamPaperSourceUser,
		SubmitterID:  user.ID,
		CourseName:   metadata.CourseName,
		AcademicYear: metadata.AcademicYear,
		Semester:     metadata.Semester,
		ExamType:     metadata.ExamType,
		Title:        metadata.Title,
		FileKey:      stored.FileKey,
		FileSize:     stored.Size,
		SHA256:       stored.SHA256,
	}
	if user.Role == models.RoleAdmin || user.Role == models.RoleSuperAdmin {
		paper.Status = models.ExamPaperStatusPublished
		paper.Source = models.ExamPaperSourceAdmin
		paper.ReviewerID = &user.ID
		paper.PublishedAt = &now
	}

	createErr := h.db.Transaction(func(tx *gorm.DB) error {
		if err := tx.Create(&paper).Error; err != nil {
			return err
		}
		if paper.Source == models.ExamPaperSourceAdmin {
			return tx.Create(&models.AdminLog{
				AdminID:   user.ID,
				AdminName: user.Nickname,
				Action:    "直接发布试卷",
				Target:    paper.Title,
				Detail:    fmt.Sprintf("试卷ID=%d，管理员直接上传，不发放经验", paper.ID),
			}).Error
		}
		return nil
	})
	if createErr != nil {
		if isExamPaperDuplicateError(createErr) {
			writeExamPaperError(c, http.StatusConflict, "duplicate_exam_paper", "该 PDF 已在待审核或已发布试卷中存在")
			return
		}
		writeExamPaperError(c, http.StatusInternalServerError, "internal_error", "保存试卷投稿失败")
		return
	}
	keepStoredFile = true
	paper.Submitter = user
	c.JSON(http.StatusCreated, examPaperToResponse(paper))
}

type createExamPaperUploadSessionRequest struct {
	CourseName       string                   `json:"course_name"`
	AcademicYear     string                   `json:"academic_year"`
	Semester         models.ExamPaperSemester `json:"semester"`
	ExamType         models.ExamPaperType     `json:"exam_type"`
	PrivacyConfirmed bool                     `json:"privacy_confirmed"`
	FileSize         int64                    `json:"file_size"`
}

type createExamPaperUploadSessionResponse struct {
	SessionID   string    `json:"session_id"`
	UploadURL   string    `json:"upload_url"`
	UploadToken string    `json:"upload_token"`
	ExpiresAt   time.Time `json:"expires_at"`
}

func bindExamPaperJSON(c *gin.Context, destination any, invalidCode, invalidMessage string) bool {
	c.Request.Body = http.MaxBytesReader(c.Writer, c.Request.Body, maxExamPaperJSONBodyBytes)
	decoder := json.NewDecoder(c.Request.Body)
	if err := decoder.Decode(destination); err != nil {
		writeExamPaperJSONDecodeError(c, err, invalidCode, invalidMessage)
		return false
	}
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		writeExamPaperJSONDecodeError(c, err, invalidCode, invalidMessage)
		return false
	}
	return true
}

func writeExamPaperJSONDecodeError(c *gin.Context, err error, invalidCode, invalidMessage string) {
	var maxBytesErr *http.MaxBytesError
	if errors.As(err, &maxBytesErr) {
		writeExamPaperError(c, http.StatusRequestEntityTooLarge, "request_body_too_large", "JSON 请求体不能超过 64 KiB")
		return
	}
	writeExamPaperError(c, http.StatusBadRequest, invalidCode, invalidMessage)
}

// CreateUploadSession 校验投稿信息并签发直传到文件服务器的短时凭证。
func (h *ExamPaperHandler) CreateUploadSession(c *gin.Context) {
	user, ok := h.currentExamPaperUser(c)
	if !ok {
		return
	}
	if h.storageMode != examPaperStorageModeRemote || h.uploads == nil || h.storageBaseURL == "" {
		writeExamPaperError(c, http.StatusServiceUnavailable, "storage_unavailable", "试卷上传暂不可用")
		return
	}

	var request createExamPaperUploadSessionRequest
	if !bindExamPaperJSON(c, &request, "invalid_upload_session_request", "上传会话参数无效") {
		return
	}
	if !request.PrivacyConfirmed {
		writeExamPaperError(c, http.StatusBadRequest, "privacy_confirmation_required", "请确认文件不含隐私信息且拥有分享权限")
		return
	}
	metadata, err := models.NormalizeExamPaperMetadata(request.CourseName, request.AcademicYear, request.Semester, request.ExamType)
	if err != nil {
		writeExamPaperError(c, http.StatusBadRequest, "invalid_exam_paper_metadata", err.Error())
		return
	}
	if request.FileSize <= 0 {
		writeExamPaperError(c, http.StatusBadRequest, "invalid_file_size", "PDF 文件大小无效")
		return
	}
	if request.FileSize > services.ExamPaperMaxFileSize {
		writeExamPaperError(c, http.StatusRequestEntityTooLarge, "file_too_large", "PDF 不能超过 20 MiB")
		return
	}
	if !isExamPaperAdmin(user) && !h.ensureExamPaperUploadAllowed(c, user) {
		return
	}

	session, token, err := h.uploads.CreateSession(user, metadata, request.FileSize)
	if err != nil {
		if errors.Is(err, services.ErrExamPaperUploadSizeInvalid) {
			writeExamPaperError(c, http.StatusBadRequest, "invalid_file_size", "PDF 文件大小无效")
			return
		}
		writeExamPaperError(c, http.StatusInternalServerError, "internal_error", "创建上传会话失败")
		return
	}
	path := "/v1/uploads/" + session.ID
	c.JSON(http.StatusCreated, createExamPaperUploadSessionResponse{
		SessionID: session.ID, UploadURL: h.storageBaseURL + path, UploadToken: token, ExpiresAt: session.ExpiresAt,
	})
}

type completeExamPaperUploadSessionRequest struct {
	Receipt string `json:"receipt"`
}

// CompleteUploadSession 验证文件服务回执并完成试卷投稿入库。
func (h *ExamPaperHandler) CompleteUploadSession(c *gin.Context) {
	user, ok := h.currentExamPaperUser(c)
	if !ok {
		return
	}
	if (h.storageMode != examPaperStorageModeRemote && h.storageMode != examPaperStorageModeReadonlyRemote) || h.uploads == nil {
		writeExamPaperError(c, http.StatusServiceUnavailable, "storage_unavailable", "试卷上传暂不可用")
		return
	}
	var request completeExamPaperUploadSessionRequest
	if !bindExamPaperJSON(c, &request, "upload_receipt_invalid", "上传回执无效") {
		return
	}
	if strings.TrimSpace(request.Receipt) == "" {
		writeExamPaperError(c, http.StatusBadRequest, "upload_receipt_invalid", "上传回执无效")
		return
	}

	paper, err := h.uploads.CompleteSession(user.ID, c.Param("id"), request.Receipt)
	if err != nil {
		h.writeUploadSessionError(c, err)
		return
	}
	c.JSON(http.StatusCreated, examPaperToResponse(*paper))
}

func (h *ExamPaperHandler) writeUploadSessionError(c *gin.Context, err error) {
	switch {
	case errors.Is(err, services.ErrExamPaperUploadSessionNotFound):
		writeExamPaperError(c, http.StatusNotFound, "upload_session_not_found", "上传会话不存在")
	case errors.Is(err, services.ErrExamPaperUploadSessionExpired):
		writeExamPaperError(c, http.StatusGone, "upload_session_expired", "上传会话已过期")
	case errors.Is(err, services.ErrExamPaperUploadReceiptInvalid):
		writeExamPaperError(c, http.StatusBadRequest, "upload_receipt_invalid", "上传回执无效")
	case errors.Is(err, services.ErrExamPaperUploadDuplicate):
		writeExamPaperError(c, http.StatusConflict, "duplicate_exam_paper", "该 PDF 已在待审核或已发布试卷中存在")
	case errors.Is(err, services.ErrExamPaperUploadQuotaExceeded):
		writeExamPaperError(c, http.StatusTooManyRequests, "exam_paper_pending_limit_reached", "待审核投稿过多，请等待审核后再继续上传")
	case errors.Is(err, services.ErrExamPaperUploadSessionInconsistent):
		writeExamPaperError(c, http.StatusConflict, "upload_session_invalid", "上传会话状态无效")
	default:
		writeExamPaperError(c, http.StatusInternalServerError, "internal_error", "完成试卷投稿失败")
	}
}

func (h *ExamPaperHandler) ensureExamPaperUploadAllowed(c *gin.Context, user models.User) bool {
	var pendingCount int64
	if err := h.db.Model(&models.ExamPaper{}).
		Where("submitter_id = ? AND status = ?", user.ID, models.ExamPaperStatusPending).
		Count(&pendingCount).Error; err != nil {
		writeExamPaperError(c, http.StatusInternalServerError, "internal_error", "检查投稿配额失败")
		return false
	}
	if pendingCount >= services.ExamPaperMaxPendingSubmissionsPerUser {
		writeExamPaperError(c, http.StatusTooManyRequests, "exam_paper_pending_limit_reached", "待审核投稿过多，请等待审核后再继续上传")
		return false
	}
	if h.uploadLimiter != nil && !h.uploadLimiter.allow(user.ID, time.Now()) {
		writeExamPaperError(c, http.StatusTooManyRequests, "exam_paper_upload_rate_limited", "上传太频繁，请稍后再试")
		return false
	}
	return true
}

const maxExamPaperFormFieldBytes int64 = 4 * 1024

// readExamPaperUpload 直接从受限请求体读取 multipart，避免 Gin 先将大 PDF 写入系统临时目录。
func (h *ExamPaperHandler) readExamPaperUpload(c *gin.Context) (map[string]string, *services.StoredExamPaperFile, error) {
	c.Request.Body = http.MaxBytesReader(c.Writer, c.Request.Body, services.ExamPaperMaxRequestBodySize)
	reader, err := c.Request.MultipartReader()
	if err != nil {
		return nil, nil, services.ErrInvalidPDF
	}

	values := make(map[string]string)
	var stored *services.StoredExamPaperFile
	for {
		part, nextErr := reader.NextPart()
		if errors.Is(nextErr, io.EOF) {
			break
		}
		if nextErr != nil {
			if isExamPaperRequestTooLarge(nextErr) {
				return values, stored, services.ErrExamPaperFileTooLarge
			}
			return values, stored, services.ErrInvalidPDF
		}

		fieldName := part.FormName()
		if fieldName == "file" {
			if stored != nil || strings.TrimSpace(part.FileName()) == "" {
				return values, stored, services.ErrInvalidPDF
			}
			stored, err = h.files.StoreUploadReader(part.FileName(), part)
			if err != nil {
				return values, stored, err
			}
			continue
		}

		if !isExamPaperFormField(fieldName) {
			// 未识别字段不参与业务逻辑；读取小片段后继续，避免意外的大字段占用资源。
			readCount, readErr := io.Copy(io.Discard, io.LimitReader(part, maxExamPaperFormFieldBytes+1))
			if readErr != nil {
				if isExamPaperRequestTooLarge(readErr) {
					return values, stored, services.ErrExamPaperFileTooLarge
				}
				return values, stored, services.ErrInvalidPDF
			}
			if readCount > maxExamPaperFormFieldBytes {
				return values, stored, services.ErrInvalidPDF
			}
			continue
		}
		if _, exists := values[fieldName]; exists {
			return values, stored, services.ErrInvalidPDF
		}
		value, err := io.ReadAll(io.LimitReader(part, maxExamPaperFormFieldBytes+1))
		if err != nil {
			if isExamPaperRequestTooLarge(err) {
				return values, stored, services.ErrExamPaperFileTooLarge
			}
			return values, stored, services.ErrInvalidPDF
		}
		if int64(len(value)) > maxExamPaperFormFieldBytes {
			return values, stored, services.ErrInvalidPDF
		}
		values[fieldName] = string(value)
	}
	if stored == nil {
		return values, nil, services.ErrInvalidPDF
	}
	return values, stored, nil
}

func isExamPaperFormField(fieldName string) bool {
	switch fieldName {
	case "course_name", "academic_year", "semester", "exam_type", "privacy_confirmed":
		return true
	default:
		return false
	}
}

func isExamPaperRequestTooLarge(err error) bool {
	var maxBytesErr *http.MaxBytesError
	if errors.As(err, &maxBytesErr) {
		return true
	}
	return strings.Contains(strings.ToLower(err.Error()), "request body too large")
}

func isExamPaperDuplicateError(err error) bool {
	if errors.Is(err, gorm.ErrDuplicatedKey) {
		return true
	}
	message := strings.ToLower(err.Error())
	return strings.Contains(message, "uq_exam_papers_active_sha256") ||
		(strings.Contains(message, "unique") && strings.Contains(message, "sha256"))
}

func (h *ExamPaperHandler) writeFileValidationError(c *gin.Context, err error) {
	switch {
	case errors.Is(err, services.ErrExamPaperFileTooLarge):
		writeExamPaperError(c, http.StatusRequestEntityTooLarge, "file_too_large", "PDF 不能超过 20 MiB")
	case errors.Is(err, services.ErrEncryptedPDF):
		writeExamPaperError(c, http.StatusBadRequest, "encrypted_pdf", "不支持加密 PDF")
	case errors.Is(err, services.ErrInvalidPDF):
		writeExamPaperError(c, http.StatusBadRequest, "invalid_pdf", "PDF 文件损坏、伪装或无法解析")
	default:
		writeExamPaperError(c, http.StatusInternalServerError, "internal_error", "处理 PDF 文件失败")
	}
}

// Preview 返回内联 PDF，不增加下载量。
func (h *ExamPaperHandler) Preview(c *gin.Context) {
	user, ok := h.currentExamPaperUser(c)
	if !ok {
		return
	}
	paper, ok := h.loadPaperForFileResponse(c, user, false)
	if !ok {
		return
	}
	if paper.StorageBackend == models.ExamPaperStorageRemote {
		h.redirectExamPaperFile(c, paper, services.ExamPaperStoragePurposePreview, false)
		return
	}
	h.serveExamPaperFile(c, paper, false)
}

// Download 仅允许下载已发布试卷，并在成功打开文件后原子增加下载量。
func (h *ExamPaperHandler) Download(c *gin.Context) {
	user, ok := h.currentExamPaperUser(c)
	if !ok {
		return
	}
	paper, ok := h.loadPaperForFileResponse(c, user, true)
	if !ok {
		return
	}
	if paper.StorageBackend == models.ExamPaperStorageRemote {
		h.redirectExamPaperFile(c, paper, services.ExamPaperStoragePurposeDownload, true)
		return
	}
	h.serveExamPaperFile(c, paper, true)
}

func (h *ExamPaperHandler) redirectExamPaperFile(c *gin.Context, paper models.ExamPaper, purpose string, countDownload bool) {
	if h.remoteFiles == nil {
		writeExamPaperError(c, http.StatusInternalServerError, "exam_paper_file_unavailable", "试卷文件暂不可用")
		return
	}
	location, err := h.remoteFiles.SignedFileURL(paper, purpose, examPaperFileGrantTTL)
	if err != nil {
		writeExamPaperError(c, http.StatusInternalServerError, "exam_paper_file_unavailable", "试卷文件暂不可用")
		return
	}
	if countDownload {
		result := h.db.Model(&models.ExamPaper{}).
			Where("id = ? AND status = ?", paper.ID, models.ExamPaperStatusPublished).
			UpdateColumn("download_count", gorm.Expr("download_count + 1"))
		if result.Error != nil || result.RowsAffected != 1 {
			writeExamPaperError(c, http.StatusInternalServerError, "internal_error", "记录下载失败")
			return
		}
	}
	c.Header("Cache-Control", "private, no-store")
	c.Header("Referrer-Policy", "no-referrer")
	c.Redirect(http.StatusFound, location)
}

func (h *ExamPaperHandler) loadPaperForFileResponse(c *gin.Context, user models.User, download bool) (models.ExamPaper, bool) {
	id, ok := parseExamPaperID(c)
	if !ok {
		return models.ExamPaper{}, false
	}
	var paper models.ExamPaper
	if err := h.db.First(&paper, id).Error; err != nil {
		writeExamPaperError(c, http.StatusNotFound, "exam_paper_not_found", "试卷不存在")
		return models.ExamPaper{}, false
	}
	isAdmin := user.Role == models.RoleAdmin || user.Role == models.RoleSuperAdmin
	if download && paper.Status != models.ExamPaperStatusPublished {
		writeExamPaperError(c, http.StatusConflict, "exam_paper_not_published", "试卷尚未发布")
		return models.ExamPaper{}, false
	}
	if !download && paper.Status != models.ExamPaperStatusPublished && !(paper.Status == models.ExamPaperStatusPending && (paper.SubmitterID == user.ID || isAdmin)) {
		writeExamPaperError(c, http.StatusForbidden, "exam_paper_forbidden", "无权预览该试卷")
		return models.ExamPaper{}, false
	}
	if paper.FileKey == "" {
		writeExamPaperError(c, http.StatusConflict, "exam_paper_not_published", "试卷文件不可用")
		return models.ExamPaper{}, false
	}
	return paper, true
}

func (h *ExamPaperHandler) serveExamPaperFile(c *gin.Context, paper models.ExamPaper, countDownload bool) {
	file, err := h.files.Open(paper.FileKey)
	if err != nil {
		writeExamPaperError(c, http.StatusInternalServerError, "exam_paper_file_unavailable", "试卷文件暂不可用")
		return
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		writeExamPaperError(c, http.StatusInternalServerError, "exam_paper_file_unavailable", "试卷文件暂不可用")
		return
	}
	if countDownload {
		if err := h.db.Model(&models.ExamPaper{}).
			Where("id = ? AND status = ?", paper.ID, models.ExamPaperStatusPublished).
			UpdateColumn("download_count", gorm.Expr("download_count + 1")).Error; err != nil {
			writeExamPaperError(c, http.StatusInternalServerError, "internal_error", "记录下载失败")
			return
		}
	}

	disposition := "inline"
	if countDownload {
		disposition = "attachment"
	}
	c.Header("Content-Type", "application/pdf")
	c.Header("X-Content-Type-Options", "nosniff")
	c.Header("Cache-Control", "private, no-store")
	c.Header("Content-Disposition", mime.FormatMediaType(disposition, map[string]string{"filename": paper.Title + ".pdf"}))
	http.ServeContent(c.Writer, c.Request, paper.Title+".pdf", info.ModTime(), file)
}

// Withdraw 允许投稿人撤回待审核投稿，或永久删除已发布、已下架的本人投稿。
func (h *ExamPaperHandler) Withdraw(c *gin.Context) {
	user, ok := h.currentExamPaperUser(c)
	if !ok {
		return
	}
	id, ok := parseExamPaperID(c)
	if !ok {
		return
	}

	var paper models.ExamPaper
	if err := h.db.Where("id = ? AND submitter_id = ?", id, user.ID).First(&paper).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			writeExamPaperError(c, http.StatusNotFound, "exam_paper_not_found", "投稿不存在")
			return
		}
		writeExamPaperError(c, http.StatusInternalServerError, "internal_error", "读取投稿失败")
		return
	}
	switch paper.Status {
	case models.ExamPaperStatusPending, models.ExamPaperStatusPublished, models.ExamPaperStatusUnpublished:
	default:
		writeExamPaperError(c, http.StatusConflict, "exam_paper_not_deletable", "当前投稿状态不允许删除")
		return
	}
	localDelete, err := h.stageLocalExamPaperDelete(paper.StorageBackend, paper.FileKey)
	if err != nil {
		writeExamPaperError(c, http.StatusInternalServerError, "exam_paper_file_unavailable", "试卷文件暂不可用")
		return
	}

	var status models.ExamPaperStatus
	rewardRevoked := false
	err = h.db.Transaction(func(tx *gorm.DB) error {
		var locked models.ExamPaper
		query := tx.Where("id = ? AND submitter_id = ?", id, user.ID)
		if tx.Dialector.Name() == "postgres" {
			query = query.Clauses(clause.Locking{Strength: "UPDATE"})
		}
		if err := query.First(&locked).Error; err != nil {
			return err
		}
		if locked.FileKey != paper.FileKey || locked.StorageBackend != paper.StorageBackend {
			return errExamPaperNotDeletable
		}
		status = locked.Status
		switch locked.Status {
		case models.ExamPaperStatusPending:
		case models.ExamPaperStatusPublished, models.ExamPaperStatusUnpublished:
			if locked.Source == models.ExamPaperSourceUser {
				var err error
				rewardRevoked, err = revokeExamPaperReward(tx, &locked, time.Now())
				if err != nil {
					return err
				}
			}
		default:
			return errExamPaperNotDeletable
		}
		if err := tx.Delete(&locked).Error; err != nil {
			return err
		}
		return h.enqueueRemoteExamPaperTrash(tx, locked.StorageBackend, locked.FileKey)
	})
	if err != nil {
		h.restoreLocalExamPaperDelete(localDelete)
		if errors.Is(err, gorm.ErrRecordNotFound) {
			writeExamPaperError(c, http.StatusNotFound, "exam_paper_not_found", "投稿不存在")
			return
		}
		if errors.Is(err, errExamPaperNotDeletable) {
			writeExamPaperError(c, http.StatusConflict, "exam_paper_not_deletable", "当前投稿状态不允许删除")
			return
		}
		writeExamPaperError(c, http.StatusInternalServerError, "internal_error", "删除投稿失败")
		return
	}
	if !h.purgeLocalExamPaperDelete(c, localDelete) {
		return
	}
	message := "投稿已永久删除"
	if status == models.ExamPaperStatusPending {
		message = "投稿已撤回"
	}
	c.JSON(http.StatusOK, gin.H{"message": message, "exp_revoked": rewardRevoked})
}

func (h *ExamPaperHandler) stageLocalExamPaperDelete(storageBackend models.ExamPaperStorageBackend, fileKey string) (*services.ExamPaperTrashMove, error) {
	if fileKey == "" || storageBackend == models.ExamPaperStorageRemote {
		return nil, nil
	}
	move, err := h.files.StageDelete(fileKey)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &move, nil
}

func (h *ExamPaperHandler) restoreLocalExamPaperDelete(move *services.ExamPaperTrashMove) {
	if move == nil {
		return
	}
	if err := h.files.RestoreDelete(*move); err != nil {
		log.Printf("恢复暂存试卷文件失败 file_key=%q: %v", move.FileKey, err)
	}
}

func (h *ExamPaperHandler) purgeLocalExamPaperDelete(c *gin.Context, move *services.ExamPaperTrashMove) bool {
	if move == nil {
		return true
	}
	if h.purgeLocalDelete == nil {
		log.Printf("试卷文件清理器未配置 file_key=%q", move.FileKey)
		writeExamPaperError(c, http.StatusInternalServerError, "exam_paper_file_cleanup_pending", "试卷文件清理待处理")
		return false
	}
	if err := h.purgeLocalDelete(*move); err != nil {
		log.Printf("清理暂存试卷文件失败 file_key=%q: %v", move.FileKey, err)
		writeExamPaperError(c, http.StatusInternalServerError, "exam_paper_file_cleanup_pending", "试卷文件清理待处理")
		return false
	}
	return true
}

func (h *ExamPaperHandler) enqueueRemoteExamPaperTrash(tx *gorm.DB, storageBackend models.ExamPaperStorageBackend, fileKey string) error {
	if storageBackend != models.ExamPaperStorageRemote || fileKey == "" {
		return nil
	}
	if h.storageJobs == nil {
		return errors.New("试卷远端存储任务服务未配置")
	}
	return h.storageJobs.EnqueueTrash(tx, storageBackend, fileKey)
}

var (
	errExamPaperNotPending   = errors.New("exam paper not pending")
	errExamPaperNotDeletable = errors.New("exam paper not deletable")
)

type examPaperReviewInput struct {
	CourseName   string                   `json:"course_name"`
	AcademicYear string                   `json:"academic_year"`
	Semester     models.ExamPaperSemester `json:"semester"`
	ExamType     models.ExamPaperType     `json:"exam_type"`
	Reason       string                   `json:"reason"`
}

type examPaperReasonInput struct {
	Reason string `json:"reason"`
}

var (
	errExamPaperNotFound     = errors.New("exam paper not found")
	errExamPaperNotPublished = errors.New("exam paper not published")
)

func (h *ExamPaperHandler) currentExamPaperAdmin(c *gin.Context) (models.User, bool) {
	user, ok := h.currentExamPaperUser(c)
	if !ok {
		return models.User{}, false
	}
	if user.Role != models.RoleAdmin && user.Role != models.RoleSuperAdmin {
		writeExamPaperError(c, http.StatusForbidden, "admin_required", "需要管理员权限")
		return models.User{}, false
	}
	return user, true
}

// AdminList 返回待审核或已发布试卷的管理列表。
func (h *ExamPaperHandler) AdminList(c *gin.Context) {
	if _, ok := h.currentExamPaperAdmin(c); !ok {
		return
	}
	status := models.ExamPaperStatus(strings.TrimSpace(c.DefaultQuery("status", string(models.ExamPaperStatusPending))))
	if status != models.ExamPaperStatusPending && status != models.ExamPaperStatusPublished {
		writeExamPaperError(c, http.StatusBadRequest, "invalid_exam_paper_status", "管理列表状态只能是 pending 或 published")
		return
	}
	page := parseExamPaperPositiveInt(c.Query("page"), 1)
	pageSize := parseExamPaperPositiveInt(c.Query("page_size"), defaultExamPaperPageSize)
	if pageSize > maxExamPaperPageSize {
		pageSize = maxExamPaperPageSize
	}
	query := h.db.Model(&models.ExamPaper{}).Where("exam_papers.status = ?", status)
	if keyword := strings.TrimSpace(c.Query("keyword")); keyword != "" {
		query = query.Where("LOWER(exam_papers.course_name) LIKE ?", "%"+strings.ToLower(keyword)+"%")
	}
	if contributor := strings.TrimSpace(c.Query("contributor")); contributor != "" {
		query = query.Joins("JOIN users ON users.id = exam_papers.submitter_id").
			Where("LOWER(users.nickname) LIKE ?", "%"+strings.ToLower(contributor)+"%")
	}
	var total int64
	if err := query.Count(&total).Error; err != nil {
		writeExamPaperError(c, http.StatusInternalServerError, "internal_error", "获取试卷管理列表失败")
		return
	}
	var papers []models.ExamPaper
	order := "exam_papers.created_at ASC, exam_papers.id ASC"
	if c.Query("sort") == "latest" {
		order = "exam_papers.created_at DESC, exam_papers.id DESC"
	}
	if err := query.Preload("Submitter").Order(order).
		Limit(pageSize).Offset((page - 1) * pageSize).Find(&papers).Error; err != nil {
		writeExamPaperError(c, http.StatusInternalServerError, "internal_error", "获取试卷管理列表失败")
		return
	}
	items := make([]examPaperResponse, 0, len(papers))
	for _, paper := range papers {
		items = append(items, examPaperToResponse(paper))
	}
	c.JSON(http.StatusOK, examPaperListResponse{Items: items, Page: page, PageSize: pageSize, Total: total})
}

// AdminPendingCount 返回独立的试卷待审核数量。
func (h *ExamPaperHandler) AdminPendingCount(c *gin.Context) {
	if _, ok := h.currentExamPaperAdmin(c); !ok {
		return
	}
	var count int64
	if err := h.db.Model(&models.ExamPaper{}).Where("status = ?", models.ExamPaperStatusPending).Count(&count).Error; err != nil {
		writeExamPaperError(c, http.StatusInternalServerError, "internal_error", "获取试卷待审核数量失败")
		return
	}
	c.JSON(http.StatusOK, gin.H{"count": count})
}

// AdminGet 返回管理员可见的单条试卷详情，但仍不暴露私有文件路径。
func (h *ExamPaperHandler) AdminGet(c *gin.Context) {
	if _, ok := h.currentExamPaperAdmin(c); !ok {
		return
	}
	id, ok := parseExamPaperID(c)
	if !ok {
		return
	}
	var paper models.ExamPaper
	if err := h.db.Preload("Submitter").First(&paper, id).Error; err != nil {
		writeExamPaperError(c, http.StatusNotFound, "exam_paper_not_found", "试卷不存在")
		return
	}
	c.JSON(http.StatusOK, examPaperToResponse(paper))
}

// AdminApprove 在行锁事务中发布试卷、发放一次经验、发送系统私信并记录日志。
func (h *ExamPaperHandler) AdminApprove(c *gin.Context) {
	admin, ok := h.currentExamPaperAdmin(c)
	if !ok {
		return
	}
	id, ok := parseExamPaperID(c)
	if !ok {
		return
	}
	var input examPaperReviewInput
	if err := c.ShouldBindJSON(&input); err != nil {
		writeExamPaperError(c, http.StatusBadRequest, "invalid_exam_paper_metadata", "审核元数据格式错误")
		return
	}
	metadata, err := models.NormalizeExamPaperMetadata(input.CourseName, input.AcademicYear, input.Semester, input.ExamType)
	if err != nil {
		writeExamPaperError(c, http.StatusBadRequest, "invalid_exam_paper_metadata", err.Error())
		return
	}
	input.Reason = strings.TrimSpace(input.Reason)
	if len([]rune(input.Reason)) > 500 {
		writeExamPaperError(c, http.StatusBadRequest, "review_reason_too_long", "审核理由不能超过500个字符")
		return
	}

	now := time.Now()
	var responsePaper models.ExamPaper
	err = h.runApprovalTransaction(func(tx *gorm.DB) error {
		var paper models.ExamPaper
		query := tx.Where("id = ?", id)
		if tx.Dialector.Name() == "postgres" {
			query = query.Clauses(clause.Locking{Strength: "UPDATE"})
		}
		if err := query.First(&paper).Error; err != nil {
			if errors.Is(err, gorm.ErrRecordNotFound) {
				return errExamPaperNotFound
			}
			return err
		}
		if paper.Status != models.ExamPaperStatusPending {
			return errExamPaperNotPending
		}

		updates := map[string]any{
			"status":          models.ExamPaperStatusPublished,
			"course_name":     metadata.CourseName,
			"academic_year":   metadata.AcademicYear,
			"semester":        metadata.Semester,
			"exam_type":       metadata.ExamType,
			"title":           metadata.Title,
			"reviewer_id":     admin.ID,
			"approval_reason": input.Reason,
			"published_at":    now,
		}
		awarded := paper.Source == models.ExamPaperSourceUser && paper.RewardedAt == nil
		if awarded {
			updates["rewarded_at"] = now
		}
		result := tx.Model(&models.ExamPaper{}).
			Where("id = ? AND status = ?", id, models.ExamPaperStatusPending).
			Updates(updates)
		if result.Error != nil {
			return result.Error
		}
		if result.RowsAffected != 1 {
			return errExamPaperNotPending
		}
		if awarded {
			if err := tx.Model(&models.User{}).Where("id = ?", paper.SubmitterID).
				UpdateColumn("exp", gorm.Expr("exp + ?", examPaperRewardExp)).Error; err != nil {
				return err
			}
		}

		message := fmt.Sprintf("你投稿的试卷《%s》已通过审核并发布。", metadata.Title)
		if awarded {
			message += fmt.Sprintf("本次投稿已奖励 %d 经验。", examPaperRewardExp)
		}
		if input.Reason != "" {
			message += "\n审核说明：" + input.Reason
		}
		if _, _, err := services.CreateSystemMessage(tx, paper.SubmitterID, message); err != nil {
			return err
		}
		if err := tx.Create(&models.AdminLog{
			AdminID:   admin.ID,
			AdminName: admin.Nickname,
			Action:    "审核通过试卷",
			Target:    metadata.Title,
			Detail:    fmt.Sprintf("试卷ID=%d，奖励经验=%t，理由=%s", id, awarded, input.Reason),
		}).Error; err != nil {
			return err
		}
		return tx.Preload("Submitter").First(&responsePaper, id).Error
	})
	if err != nil {
		h.writeAdminTransactionError(c, err)
		return
	}
	c.JSON(http.StatusOK, examPaperToResponse(responsePaper))
}

// AdminReject 拒绝待审核投稿，并在事务提交后尽力删除私有文件。
func (h *ExamPaperHandler) AdminReject(c *gin.Context) {
	admin, ok := h.currentExamPaperAdmin(c)
	if !ok {
		return
	}
	id, ok := parseExamPaperID(c)
	if !ok {
		return
	}
	var input examPaperReasonInput
	if err := c.ShouldBindJSON(&input); err != nil {
		writeExamPaperError(c, http.StatusBadRequest, "review_reason_required", "拒绝理由不能为空")
		return
	}
	input.Reason = strings.TrimSpace(input.Reason)
	if input.Reason == "" {
		writeExamPaperError(c, http.StatusBadRequest, "review_reason_required", "拒绝理由不能为空")
		return
	}
	if len([]rune(input.Reason)) > 500 {
		writeExamPaperError(c, http.StatusBadRequest, "review_reason_too_long", "拒绝理由不能超过500个字符")
		return
	}

	var paper models.ExamPaper
	if err := h.db.First(&paper, id).Error; err != nil {
		writeExamPaperError(c, http.StatusNotFound, "exam_paper_not_found", "试卷不存在")
		return
	}
	if paper.Status != models.ExamPaperStatusPending {
		writeExamPaperError(c, http.StatusConflict, "exam_paper_not_pending", "试卷已不处于待审核状态")
		return
	}
	localDelete, err := h.stageLocalExamPaperDelete(paper.StorageBackend, paper.FileKey)
	if err != nil {
		writeExamPaperError(c, http.StatusInternalServerError, "exam_paper_file_unavailable", "试卷文件暂不可用")
		return
	}

	err = h.db.Transaction(func(tx *gorm.DB) error {
		var locked models.ExamPaper
		query := tx.Where("id = ?", id)
		if tx.Dialector.Name() == "postgres" {
			query = query.Clauses(clause.Locking{Strength: "UPDATE"})
		}
		if err := query.First(&locked).Error; err != nil {
			if errors.Is(err, gorm.ErrRecordNotFound) {
				return errExamPaperNotFound
			}
			return err
		}
		if locked.Status != models.ExamPaperStatusPending || locked.FileKey != paper.FileKey || locked.StorageBackend != paper.StorageBackend {
			return errExamPaperNotPending
		}
		message := fmt.Sprintf("你投稿的试卷《%s》未通过审核。\n拒绝理由：%s", locked.Title, input.Reason)
		if _, _, err := services.CreateSystemMessage(tx, locked.SubmitterID, message); err != nil {
			return err
		}
		if err := tx.Create(&models.AdminLog{
			AdminID:   admin.ID,
			AdminName: admin.Nickname,
			Action:    "拒绝试卷投稿",
			Target:    locked.Title,
			Detail:    fmt.Sprintf("试卷ID=%d，理由=%s", id, input.Reason),
		}).Error; err != nil {
			return err
		}
		if err := tx.Delete(&locked).Error; err != nil {
			return err
		}
		return h.enqueueRemoteExamPaperTrash(tx, locked.StorageBackend, locked.FileKey)
	})
	if err != nil {
		h.restoreLocalExamPaperDelete(localDelete)
		h.writeAdminTransactionError(c, err)
		return
	}
	if !h.purgeLocalExamPaperDelete(c, localDelete) {
		return
	}
	c.JSON(http.StatusOK, gin.H{"message": "投稿已拒绝并删除"})
}

// AdminUpdate 编辑已发布试卷元数据并重新生成标题。
func (h *ExamPaperHandler) AdminUpdate(c *gin.Context) {
	admin, ok := h.currentExamPaperAdmin(c)
	if !ok {
		return
	}
	id, ok := parseExamPaperID(c)
	if !ok {
		return
	}
	var input examPaperReviewInput
	if err := c.ShouldBindJSON(&input); err != nil {
		writeExamPaperError(c, http.StatusBadRequest, "invalid_exam_paper_metadata", "试卷元数据格式错误")
		return
	}
	metadata, err := models.NormalizeExamPaperMetadata(input.CourseName, input.AcademicYear, input.Semester, input.ExamType)
	if err != nil {
		writeExamPaperError(c, http.StatusBadRequest, "invalid_exam_paper_metadata", err.Error())
		return
	}
	var responsePaper models.ExamPaper
	err = h.db.Transaction(func(tx *gorm.DB) error {
		var paper models.ExamPaper
		query := tx.Where("id = ?", id)
		if tx.Dialector.Name() == "postgres" {
			query = query.Clauses(clause.Locking{Strength: "UPDATE"})
		}
		if err := query.First(&paper).Error; err != nil {
			if errors.Is(err, gorm.ErrRecordNotFound) {
				return errExamPaperNotFound
			}
			return err
		}
		if paper.Status != models.ExamPaperStatusPublished {
			return errExamPaperNotPublished
		}
		if err := tx.Model(&paper).Updates(map[string]any{
			"course_name": metadata.CourseName, "academic_year": metadata.AcademicYear,
			"semester": metadata.Semester, "exam_type": metadata.ExamType, "title": metadata.Title,
		}).Error; err != nil {
			return err
		}
		if err := tx.Create(&models.AdminLog{
			AdminID: admin.ID, AdminName: admin.Nickname, Action: "编辑已发布试卷",
			Target: metadata.Title, Detail: fmt.Sprintf("试卷ID=%d", id),
		}).Error; err != nil {
			return err
		}
		return tx.Preload("Submitter").First(&responsePaper, id).Error
	})
	if err != nil {
		h.writeAdminTransactionError(c, err)
		return
	}
	c.JSON(http.StatusOK, examPaperToResponse(responsePaper))
}

// AdminUnpublish 下架已发布试卷，保留元数据和哈希，但删除可访问文件。
func (h *ExamPaperHandler) AdminUnpublish(c *gin.Context) {
	admin, ok := h.currentExamPaperAdmin(c)
	if !ok {
		return
	}
	id, ok := parseExamPaperID(c)
	if !ok {
		return
	}
	var input examPaperReasonInput
	if err := c.ShouldBindJSON(&input); err != nil {
		writeExamPaperError(c, http.StatusBadRequest, "unpublish_reason_required", "下架理由不能为空")
		return
	}
	input.Reason = strings.TrimSpace(input.Reason)
	if input.Reason == "" {
		writeExamPaperError(c, http.StatusBadRequest, "unpublish_reason_required", "下架理由不能为空")
		return
	}
	if len([]rune(input.Reason)) > 500 {
		writeExamPaperError(c, http.StatusBadRequest, "unpublish_reason_too_long", "下架理由不能超过500个字符")
		return
	}
	var paper models.ExamPaper
	if err := h.db.First(&paper, id).Error; err != nil {
		writeExamPaperError(c, http.StatusNotFound, "exam_paper_not_found", "试卷不存在")
		return
	}
	if paper.Status != models.ExamPaperStatusPublished {
		writeExamPaperError(c, http.StatusConflict, "exam_paper_not_published", "只有已发布试卷可以下架")
		return
	}
	localDelete, err := h.stageLocalExamPaperDelete(paper.StorageBackend, paper.FileKey)
	if err != nil {
		writeExamPaperError(c, http.StatusInternalServerError, "exam_paper_file_unavailable", "试卷文件暂不可用")
		return
	}
	now := time.Now()
	var responsePaper models.ExamPaper
	err = h.db.Transaction(func(tx *gorm.DB) error {
		var locked models.ExamPaper
		query := tx.Where("id = ?", id)
		if tx.Dialector.Name() == "postgres" {
			query = query.Clauses(clause.Locking{Strength: "UPDATE"})
		}
		if err := query.First(&locked).Error; err != nil {
			if errors.Is(err, gorm.ErrRecordNotFound) {
				return errExamPaperNotFound
			}
			return err
		}
		if locked.Status != models.ExamPaperStatusPublished || locked.FileKey != paper.FileKey || locked.StorageBackend != paper.StorageBackend {
			return errExamPaperNotPublished
		}
		rewardRevoked, err := revokeExamPaperReward(tx, &locked, now)
		if err != nil {
			return err
		}
		originalFileKey := locked.FileKey
		if err := tx.Model(&locked).Updates(map[string]any{
			"status": models.ExamPaperStatusUnpublished, "file_key": "",
			"unpublisher_id": admin.ID, "unpublish_reason": input.Reason, "unpublished_at": now,
		}).Error; err != nil {
			return err
		}
		if err := h.enqueueRemoteExamPaperTrash(tx, locked.StorageBackend, originalFileKey); err != nil {
			return err
		}
		message := fmt.Sprintf("你投稿的试卷《%s》已下架。\n下架理由：%s", locked.Title, input.Reason)
		if rewardRevoked {
			message += fmt.Sprintf("\n该投稿获得的 %d 经验已扣回。", examPaperRewardExp)
		}
		if _, _, err := services.CreateSystemMessage(tx, locked.SubmitterID, message); err != nil {
			return err
		}
		if err := tx.Create(&models.AdminLog{
			AdminID: admin.ID, AdminName: admin.Nickname, Action: "下架试卷",
			Target: locked.Title, Detail: fmt.Sprintf("试卷ID=%d，撤销经验=%t，理由=%s", id, rewardRevoked, input.Reason),
		}).Error; err != nil {
			return err
		}
		return tx.Preload("Submitter").First(&responsePaper, id).Error
	})
	if err != nil {
		h.restoreLocalExamPaperDelete(localDelete)
		h.writeAdminTransactionError(c, err)
		return
	}
	if !h.purgeLocalExamPaperDelete(c, localDelete) {
		return
	}
	c.JSON(http.StatusOK, examPaperToResponse(responsePaper))
}

func (h *ExamPaperHandler) writeAdminTransactionError(c *gin.Context, err error) {
	switch {
	case errors.Is(err, errExamPaperNotFound), errors.Is(err, gorm.ErrRecordNotFound):
		writeExamPaperError(c, http.StatusNotFound, "exam_paper_not_found", "试卷不存在")
	case errors.Is(err, errExamPaperNotPending):
		writeExamPaperError(c, http.StatusConflict, "exam_paper_not_pending", "试卷已不处于待审核状态")
	case errors.Is(err, errExamPaperNotPublished):
		writeExamPaperError(c, http.StatusConflict, "exam_paper_not_published", "试卷已不处于发布状态")
	default:
		writeExamPaperError(c, http.StatusInternalServerError, "internal_error", "试卷管理操作失败")
	}
}

func (h *ExamPaperHandler) runApprovalTransaction(operation func(tx *gorm.DB) error) error {
	var lastErr error
	for attempt := 0; attempt < 5; attempt++ {
		lastErr = h.db.Transaction(operation)
		if lastErr == nil || !isDatabaseBusyError(lastErr) {
			return lastErr
		}
		time.Sleep(time.Duration(attempt+1) * 20 * time.Millisecond)
	}
	return lastErr
}

func isDatabaseBusyError(err error) bool {
	if err == nil {
		return false
	}
	message := strings.ToLower(err.Error())
	return strings.Contains(message, "database is locked") || strings.Contains(message, "sqlite_busy")
}
