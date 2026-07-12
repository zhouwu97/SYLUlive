package services

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"mime/multipart"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/pdfcpu/pdfcpu/pkg/api"
	"github.com/pdfcpu/pdfcpu/pkg/pdfcpu/model"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

const (
	// ExamPaperMaxFileSize 是服务端允许的 PDF 最大字节数（20 MiB）。
	ExamPaperMaxFileSize int64 = 20 * 1024 * 1024
)

var (
	ErrInvalidPDF              = errors.New("invalid pdf")
	ErrEncryptedPDF            = errors.New("encrypted pdf")
	ErrExamPaperFileTooLarge   = errors.New("exam paper file too large")
	ErrInvalidExamPaperFileKey = errors.New("invalid exam paper file key")
	pdfCPUConfigOnce           sync.Once
)

// StoredExamPaperFile 是完成校验并落盘后的私有文件信息。
type StoredExamPaperFile struct {
	FileKey string
	Size    int64
	SHA256  string
}

// ExamPaperTrashMove 描述同一文件系统内的一次原子暂存删除。
type ExamPaperTrashMove struct {
	FileKey      string
	OriginalPath string
	TrashPath    string
}

// ExamPaperFileService 管理试卷私有目录、校验、原子删除和启动恢复。
type ExamPaperFileService struct {
	rootDir                  string
	trashDir                 string
	pendingDir               string
	lifecycleMu              sync.Mutex
	claimIntentMu            sync.Mutex
	claimIntents             map[string]int
	maintenanceAfterSnapshot func()
	trashRename              func(string, string) error
	chmod                    func(string, os.FileMode) error
	remove                   func(string) error
	claimAfterIntent         func()
	claimRemove              func(string) error
}

// NewExamPaperFileService 初始化权限为 0700 的私有目录和垃圾目录。
func NewExamPaperFileService(rootDir string) (*ExamPaperFileService, error) {
	if strings.TrimSpace(rootDir) == "" {
		return nil, fmt.Errorf("试卷私有目录不能为空")
	}
	absoluteRoot, err := filepath.Abs(rootDir)
	if err != nil {
		return nil, fmt.Errorf("解析试卷私有目录失败: %w", err)
	}
	trashDir := filepath.Join(absoluteRoot, ".trash")
	pendingDir := filepath.Join(absoluteRoot, ".pending")
	for _, dir := range []string{absoluteRoot, trashDir, pendingDir} {
		if info, statErr := os.Lstat(dir); statErr == nil {
			if info.Mode()&os.ModeSymlink != 0 {
				return nil, fmt.Errorf("试卷存储目录不得为符号链接")
			}
			if !info.IsDir() {
				return nil, fmt.Errorf("试卷存储路径必须为目录")
			}
		} else if os.IsNotExist(statErr) {
			if err := os.MkdirAll(dir, 0o700); err != nil {
				return nil, fmt.Errorf("创建试卷私有目录失败: %w", err)
			}
		} else {
			return nil, fmt.Errorf("检查试卷私有目录失败: %w", statErr)
		}
		if err := os.Chmod(dir, 0o700); err != nil {
			return nil, fmt.Errorf("设置试卷私有目录权限失败: %w", err)
		}
	}

	pdfCPUConfigOnce.Do(api.DisableConfigDir)
	return &ExamPaperFileService{rootDir: absoluteRoot, trashDir: trashDir, pendingDir: pendingDir, trashRename: os.Rename, chmod: os.Chmod, remove: os.Remove, claimRemove: os.Remove, claimIntents: make(map[string]int)}, nil
}

// RootDir 返回私有根目录，仅供启动与测试代码使用。
func (s *ExamPaperFileService) RootDir() string {
	return s.rootDir
}

// ExamPaperMaxRequestBodySize 为 multipart 额外字段和边界预留 1 MiB，PDF 本体仍严格限制为 20 MiB。
const ExamPaperMaxRequestBodySize int64 = ExamPaperMaxFileSize + 1024*1024

// StoreUpload 兼容已有 FileHeader 调用，并将实际落盘逻辑委托给流式读取接口。
func (s *ExamPaperFileService) StoreUpload(header *multipart.FileHeader) (_ *StoredExamPaperFile, err error) {
	if header == nil {
		return nil, ErrInvalidPDF
	}
	if header.Size > ExamPaperMaxFileSize {
		return nil, ErrExamPaperFileTooLarge
	}

	source, err := header.Open()
	if err != nil {
		return nil, fmt.Errorf("打开上传文件失败: %w", err)
	}
	defer source.Close()
	return s.StoreUploadReader(header.Filename, source)
}

// StoreUploadReader 流式保存、计算 SHA-256，并用 pdfcpu 验证 PDF 结构和加密状态。
// 调用方应确保 reader 直接来自受限的 HTTP 请求体，避免框架先将大文件写入系统临时目录。
func (s *ExamPaperFileService) StoreUploadReader(filename string, source io.Reader) (_ *StoredExamPaperFile, err error) {
	return s.storeUploadReader(filename, source, false)
}

// StorePendingUploadReader 在生命周期锁内提交文件和待认领标记，避免落盘孤儿。
func (s *ExamPaperFileService) StorePendingUploadReader(filename string, source io.Reader) (*StoredExamPaperFile, error) {
	return s.storeUploadReader(filename, source, true)
}

func (s *ExamPaperFileService) storeUploadReader(filename string, source io.Reader, pending bool) (_ *StoredExamPaperFile, err error) {
	if source == nil || !strings.EqualFold(filepath.Ext(filename), ".pdf") {
		return nil, ErrInvalidPDF
	}

	tempPath := filepath.Join(s.rootDir, ".upload-"+uuid.NewString())
	tempFile, err := os.OpenFile(tempPath, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return nil, fmt.Errorf("创建临时文件失败: %w", err)
	}
	tempKept := false
	defer func() {
		if !tempKept {
			_ = os.Remove(tempPath)
		}
	}()

	hash := sha256.New()
	limited := &io.LimitedReader{R: source, N: ExamPaperMaxFileSize + 1}
	written, copyErr := io.Copy(io.MultiWriter(tempFile, hash), limited)
	closeErr := tempFile.Close()
	if copyErr != nil {
		return nil, fmt.Errorf("保存上传文件失败: %w", copyErr)
	}
	if closeErr != nil {
		return nil, fmt.Errorf("关闭上传文件失败: %w", closeErr)
	}
	if written > ExamPaperMaxFileSize {
		return nil, ErrExamPaperFileTooLarge
	}
	if written < 5 {
		return nil, ErrInvalidPDF
	}

	prefixFile, err := os.Open(tempPath)
	if err != nil {
		return nil, fmt.Errorf("检查 PDF 文件头失败: %w", err)
	}
	prefix := make([]byte, 5)
	_, readErr := io.ReadFull(prefixFile, prefix)
	_ = prefixFile.Close()
	if readErr != nil || string(prefix) != "%PDF-" {
		return nil, ErrInvalidPDF
	}

	if err := validateExamPaperPDF(tempPath); err != nil {
		return nil, err
	}

	fileKey := uuid.NewString() + ".pdf"
	finalPath := filepath.Join(s.rootDir, fileKey)
	if pending {
		s.lifecycleMu.Lock()
		defer s.lifecycleMu.Unlock()
		if err := s.createPendingMarkerLocked(fileKey); err != nil {
			return nil, err
		}
	}
	if err := os.Rename(tempPath, finalPath); err != nil {
		if pending {
			_ = os.Remove(filepath.Join(s.pendingDir, fileKey))
		}
		return nil, fmt.Errorf("提交试卷文件失败: %w", err)
	}
	tempKept = true
	if err := s.chmod(finalPath, 0o600); err != nil {
		removeErr := s.remove(finalPath)
		if pending && (removeErr == nil || os.IsNotExist(removeErr)) {
			_ = s.remove(filepath.Join(s.pendingDir, fileKey))
		}
		return nil, fmt.Errorf("设置试卷文件权限失败: %w", err)
	}

	return &StoredExamPaperFile{
		FileKey: fileKey,
		Size:    written,
		SHA256:  hex.EncodeToString(hash.Sum(nil)),
	}, nil
}

func validateExamPaperPDF(path string) error {
	file, err := os.Open(path)
	if err != nil {
		return fmt.Errorf("打开 PDF 进行解析失败: %w", err)
	}
	defer file.Close()

	conf := model.NewDefaultConfiguration()
	conf.CheckFileNameExt = false
	conf.Offline = true
	conf.DecodeAllStreams = false
	conf.Optimize = false
	conf.ValidationMode = model.ValidationRelaxed
	conf.Limits = model.ResourceLimits{
		MaxStreamBytes:       64 * 1024 * 1024,
		MaxDecodeBytes:       256 * 1024 * 1024,
		MaxImagePixels:       50 * 1024 * 1024,
		MaxImageBytes:        256 * 1024 * 1024,
		MaxObjectCount:       1_000_000,
		MaxObjectStreamCount: 100_000,
		MaxObjectStreamFirst: 8 * 1024 * 1024,
		MaxXRefEntries:       1_000_000,
		MaxRecursionDepth:    64,
	}

	ctx, err := api.ReadContext(file, conf)
	if err != nil {
		lower := strings.ToLower(err.Error())
		if strings.Contains(lower, "password") || strings.Contains(lower, "encrypted") {
			return fmt.Errorf("%w: %v", ErrEncryptedPDF, err)
		}
		return fmt.Errorf("%w: %v", ErrInvalidPDF, err)
	}
	if ctx.Encrypt != nil {
		return ErrEncryptedPDF
	}
	if err := api.ValidateContext(ctx); err != nil {
		return fmt.Errorf("%w: %v", ErrInvalidPDF, err)
	}
	return nil
}

// Open 安全打开私有文件，拒绝路径穿越和非基础文件名。
func (s *ExamPaperFileService) Open(fileKey string) (*os.File, error) {
	path, err := s.resolveFileKey(fileKey)
	if err != nil {
		return nil, err
	}
	if _, err := s.Stat(fileKey); err != nil {
		return nil, err
	}
	return os.Open(path)
}

// StageDelete 将文件原子移动到同一文件系统的 .trash 目录。
func (s *ExamPaperFileService) StageDelete(fileKey string) (ExamPaperTrashMove, error) {
	originalPath, err := s.resolveFileKey(fileKey)
	if err != nil {
		return ExamPaperTrashMove{}, err
	}
	trashPath := filepath.Join(s.trashDir, uuid.NewString()+"--"+fileKey)
	if err := os.Rename(originalPath, trashPath); err != nil {
		return ExamPaperTrashMove{}, err
	}
	return ExamPaperTrashMove{FileKey: fileKey, OriginalPath: originalPath, TrashPath: trashPath}, nil
}

// RestoreDelete 在数据库事务失败时恢复已暂存文件。
func (s *ExamPaperFileService) RestoreDelete(move ExamPaperTrashMove) error {
	if move.OriginalPath == "" || move.TrashPath == "" {
		return nil
	}
	if _, err := os.Stat(move.OriginalPath); err == nil {
		return os.Remove(move.TrashPath)
	} else if !os.IsNotExist(err) {
		return err
	}
	return os.Rename(move.TrashPath, move.OriginalPath)
}

// PurgeDelete 在数据库事务提交后物理清除垃圾文件。
func (s *ExamPaperFileService) PurgeDelete(move ExamPaperTrashMove) error {
	if move.TrashPath == "" {
		return nil
	}
	if err := os.Remove(move.TrashPath); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}

// Remove 仅用于数据库写入失败时清理尚未被任何记录引用的新文件。
func (s *ExamPaperFileService) Remove(fileKey string) error {
	path, err := s.resolveFileKey(fileKey)
	if err != nil {
		return err
	}
	if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}

// MarkPending 创建仅文件服务可见的待认领标记。
func (s *ExamPaperFileService) MarkPending(fileKey string) error {
	s.lifecycleMu.Lock()
	defer s.lifecycleMu.Unlock()
	return s.createPendingMarkerLocked(fileKey)
}

func (s *ExamPaperFileService) createPendingMarkerLocked(fileKey string) error {
	if _, err := s.resolveFileKey(fileKey); err != nil {
		return err
	}
	markerPath := filepath.Join(s.pendingDir, fileKey)
	file, err := os.OpenFile(markerPath, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	if err := file.Close(); err != nil {
		_ = os.Remove(markerPath)
		return err
	}
	return nil
}

// Claim 幂等移除待认领标记。
func (s *ExamPaperFileService) Claim(fileKey string) error {
	s.claimIntentMu.Lock()
	s.claimIntents[fileKey]++
	s.claimIntentMu.Unlock()
	if s.claimAfterIntent != nil {
		s.claimAfterIntent()
	}
	defer func() {
		s.claimIntentMu.Lock()
		if count := s.claimIntents[fileKey]; count <= 1 {
			delete(s.claimIntents, fileKey)
		} else {
			s.claimIntents[fileKey] = count - 1
		}
		s.claimIntentMu.Unlock()
	}()
	s.lifecycleMu.Lock()
	defer s.lifecycleMu.Unlock()
	return s.claimLocked(fileKey)
}

func (s *ExamPaperFileService) claimIntentExists(fileKey string) bool {
	s.claimIntentMu.Lock()
	defer s.claimIntentMu.Unlock()
	return s.claimIntents[fileKey] > 0
}

func (s *ExamPaperFileService) claimLocked(fileKey string) error {
	if _, err := s.resolveFileKey(fileKey); err != nil {
		return err
	}
	if err := s.claimRemove(filepath.Join(s.pendingDir, fileKey)); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}

// Trash 幂等地将文件移入回收站，并清理待认领标记。
func (s *ExamPaperFileService) Trash(fileKey string) error {
	s.lifecycleMu.Lock()
	defer s.lifecycleMu.Unlock()
	originalPath, err := s.resolveFileKey(fileKey)
	if err != nil {
		return err
	}
	if _, err := s.Stat(fileKey); os.IsNotExist(err) {
		return s.claimLocked(fileKey)
	} else if err != nil {
		return err
	}
	trashPath := filepath.Join(s.trashDir, uuid.NewString()+"--"+fileKey)
	if err := s.trashRename(originalPath, trashPath); err != nil {
		return err
	}
	if err := os.Chmod(trashPath, 0o600); err != nil {
		return err
	}
	return s.claimLocked(fileKey)
}

// DiscardPending 原子删除待认领文件；文件删除失败时保留 marker 供维护清理。
func (s *ExamPaperFileService) DiscardPending(fileKey string) error {
	s.lifecycleMu.Lock()
	defer s.lifecycleMu.Unlock()
	path, err := s.resolveFileKey(fileKey)
	if err != nil {
		return err
	}
	if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
		return err
	}
	return s.claimLocked(fileKey)
}

// Stat 轻量检查文件存在、为普通文件且不是符号链接。
func (s *ExamPaperFileService) Stat(fileKey string) (os.FileInfo, error) {
	path, err := s.resolveFileKey(fileKey)
	if err != nil {
		return nil, err
	}
	info, err := os.Lstat(path)
	if err != nil {
		return nil, err
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
		return nil, ErrInvalidExamPaperFileKey
	}
	return info, nil
}

// Metadata 从磁盘重新读取文件大小和 SHA-256，避免返回过期信息。
func (s *ExamPaperFileService) Metadata(fileKey string) (*StoredExamPaperFile, error) {
	path, err := s.resolveFileKey(fileKey)
	if err != nil {
		return nil, err
	}
	if _, err := s.Stat(fileKey); err != nil {
		return nil, err
	}
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	hash := sha256.New()
	size, err := io.Copy(hash, file)
	if err != nil {
		return nil, err
	}
	return &StoredExamPaperFile{FileKey: fileKey, Size: size, SHA256: hex.EncodeToString(hash.Sum(nil))}, nil
}

// ExamPaperMaintenanceResult 汇总一次文件存储维护实际删除的内容。
type ExamPaperMaintenanceResult struct {
	UnclaimedFilesRemoved int `json:"unclaimed_files_removed"`
	PendingMarkersRemoved int `json:"pending_markers_removed"`
	TrashFilesRemoved     int `json:"trash_files_removed"`
	TemporaryFilesRemoved int `json:"temporary_files_removed"`
}

// Maintenance 清理超过七天仍未认领的文件和超过七天的回收站文件。
func (s *ExamPaperFileService) Maintenance(now time.Time) (ExamPaperMaintenanceResult, error) {
	result := ExamPaperMaintenanceResult{}
	cutoff := now.Add(-7 * 24 * time.Hour)
	tempCutoff := now.Add(-time.Hour)
	s.lifecycleMu.Lock()
	defer s.lifecycleMu.Unlock()
	pendingEntries, err := os.ReadDir(s.pendingDir)
	if err != nil {
		return result, err
	}
	stalePending := make([]string, 0, len(pendingEntries))
	for _, entry := range pendingEntries {
		if entry.IsDir() {
			continue
		}
		info, err := entry.Info()
		if err == nil && info.ModTime().Before(cutoff) {
			stalePending = append(stalePending, entry.Name())
		}
	}
	if s.maintenanceAfterSnapshot != nil {
		s.maintenanceAfterSnapshot()
	}
	for _, fileKey := range stalePending {
		if s.claimIntentExists(fileKey) {
			continue
		}
		markerPath := filepath.Join(s.pendingDir, fileKey)
		info, infoErr := os.Stat(markerPath)
		if infoErr != nil || !info.ModTime().Before(cutoff) {
			continue
		}
		if path, resolveErr := s.resolveFileKey(fileKey); resolveErr == nil {
			if removeErr := os.Remove(path); removeErr == nil {
				result.UnclaimedFilesRemoved++
			} else if !os.IsNotExist(removeErr) {
				return result, removeErr
			}
		}
		if removeErr := os.Remove(filepath.Join(s.pendingDir, fileKey)); removeErr == nil {
			result.PendingMarkersRemoved++
		} else if !os.IsNotExist(removeErr) {
			return result, removeErr
		}
	}
	trashEntries, err := os.ReadDir(s.trashDir)
	if err != nil {
		return result, err
	}
	for _, entry := range trashEntries {
		if entry.IsDir() {
			continue
		}
		info, err := entry.Info()
		if err != nil || !info.ModTime().Before(cutoff) {
			continue
		}
		if err := os.Remove(filepath.Join(s.trashDir, entry.Name())); err == nil {
			result.TrashFilesRemoved++
		} else if !os.IsNotExist(err) {
			return result, err
		}
	}
	rootEntries, err := os.ReadDir(s.rootDir)
	if err != nil {
		return result, err
	}
	for _, entry := range rootEntries {
		if entry.IsDir() || !strings.HasPrefix(entry.Name(), ".upload-") {
			continue
		}
		info, infoErr := entry.Info()
		if infoErr == nil && info.ModTime().Before(tempCutoff) {
			if removeErr := os.Remove(filepath.Join(s.rootDir, entry.Name())); removeErr == nil {
				result.TemporaryFilesRemoved++
			} else if !os.IsNotExist(removeErr) {
				return result, removeErr
			}
		}
	}
	return result, nil
}

// RecoverTrash 根据数据库引用恢复仍有效的文件，并清理无引用垃圾文件。
func (s *ExamPaperFileService) RecoverTrash(db *gorm.DB) error {
	entries, err := os.ReadDir(s.trashDir)
	if err != nil {
		return fmt.Errorf("读取试卷垃圾目录失败: %w", err)
	}
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		parts := strings.SplitN(entry.Name(), "--", 2)
		trashPath := filepath.Join(s.trashDir, entry.Name())
		if len(parts) != 2 {
			_ = os.Remove(trashPath)
			continue
		}
		fileKey := parts[1]
		originalPath, resolveErr := s.resolveFileKey(fileKey)
		if resolveErr != nil {
			_ = os.Remove(trashPath)
			continue
		}

		var referenced int64
		if err := db.Model(&models.ExamPaper{}).
			Where("file_key = ? AND status IN ?", fileKey, []models.ExamPaperStatus{
				models.ExamPaperStatusPending,
				models.ExamPaperStatusPublished,
			}).
			Count(&referenced).Error; err != nil {
			return fmt.Errorf("检查试卷文件引用失败: %w", err)
		}

		if referenced == 0 {
			if err := os.Remove(trashPath); err != nil && !os.IsNotExist(err) {
				return fmt.Errorf("清理无引用试卷文件失败: %w", err)
			}
			continue
		}

		if _, err := os.Stat(originalPath); err == nil {
			if err := os.Remove(trashPath); err != nil && !os.IsNotExist(err) {
				return fmt.Errorf("清理重复垃圾文件失败: %w", err)
			}
			continue
		} else if !os.IsNotExist(err) {
			return err
		}
		if err := os.Rename(trashPath, originalPath); err != nil {
			return fmt.Errorf("恢复仍被引用的试卷文件失败: %w", err)
		}
		_ = os.Chmod(originalPath, 0o600)
	}

	// 启动时清理一小时前遗留的随机上传临时文件。
	rootEntries, err := os.ReadDir(s.rootDir)
	if err != nil {
		return err
	}
	cutoff := time.Now().Add(-time.Hour)
	for _, entry := range rootEntries {
		if entry.IsDir() || !strings.HasPrefix(entry.Name(), ".upload-") {
			continue
		}
		info, infoErr := entry.Info()
		if infoErr == nil && info.ModTime().Before(cutoff) {
			_ = os.Remove(filepath.Join(s.rootDir, entry.Name()))
		}
	}
	return nil
}

func (s *ExamPaperFileService) resolveFileKey(fileKey string) (string, error) {
	if fileKey == "" || filepath.Base(fileKey) != fileKey || strings.ContainsAny(fileKey, `/\\`) {
		return "", ErrInvalidExamPaperFileKey
	}
	resolved := filepath.Join(s.rootDir, fileKey)
	if filepath.Dir(resolved) != s.rootDir {
		return "", ErrInvalidExamPaperFileKey
	}
	return resolved, nil
}
