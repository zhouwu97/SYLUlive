package services

import (
	"context"
	"errors"
	"fmt"
	"image"
	"image/jpeg"
	"image/png"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"shenliyuan/internal/models"

	xdraw "golang.org/x/image/draw"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"
)

const (
	defaultImageVariantMaxAttempts = 3
	defaultImageVariantPoll        = 250 * time.Millisecond
	imageVariantLease              = 10 * time.Minute
)

// ImageVariantWorker 从数据库领取并生成图片变体，进程重启后可继续处理未完成任务。
type ImageVariantWorker struct {
	db           *gorm.DB
	uploadDir    string
	maxAttempts  int
	pollInterval time.Duration
	now          func() time.Time
}

// NewImageVariantWorker 创建使用默认小并发配置的单个 worker。
func NewImageVariantWorker(db *gorm.DB, uploadDir string) *ImageVariantWorker {
	return &ImageVariantWorker{
		db:           db,
		uploadDir:    uploadDir,
		maxAttempts:  defaultImageVariantMaxAttempts,
		pollInterval: defaultImageVariantPoll,
		now:          time.Now,
	}
}

// StartImageVariantWorkers 启动有限数量的后台 worker，所有 goroutine 都随 ctx 结束。
func StartImageVariantWorkers(ctx context.Context, db *gorm.DB, uploadDir string, workerCount int) {
	if workerCount <= 0 {
		workerCount = 1
	}
	for range workerCount {
		worker := NewImageVariantWorker(db, uploadDir)
		go worker.Start(ctx)
	}
}

// Start 持续轮询任务表；单个任务错误只影响自身状态，不中断后台循环。
func (worker *ImageVariantWorker) Start(ctx context.Context) {
	for {
		if err := ctx.Err(); err != nil {
			return
		}
		worked, err := worker.ProcessNext(ctx)
		if err != nil {
			log.Printf("[IMAGE_VARIANT_WORKER] 处理任务失败: %v", err)
		}
		if worked && err == nil {
			continue
		}
		timer := time.NewTimer(worker.pollInterval)
		select {
		case <-ctx.Done():
			if !timer.Stop() {
				<-timer.C
			}
			return
		case <-timer.C:
		}
	}
}

// ProcessNext 领取并处理最多一个任务。业务失败会写入任务状态，而非中断 worker。
func (worker *ImageVariantWorker) ProcessNext(ctx context.Context) (bool, error) {
	job, found, err := worker.claimNext(ctx)
	if err != nil || !found {
		return false, err
	}
	if err := worker.generate(job); err != nil {
		return true, worker.markFailed(job, err)
	}
	if err := worker.markReady(job); err != nil {
		return true, err
	}
	return true, nil
}

func (worker *ImageVariantWorker) claimNext(ctx context.Context) (models.ImageVariant, bool, error) {
	var job models.ImageVariant
	found := false
	now := worker.now()
	err := worker.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		// 进程在领取后崩溃时回收陈旧 running 任务，避免版本 URL 永久 404。
		staleBefore := now.Add(-imageVariantLease)
		if err := tx.Model(&models.ImageVariant{}).
			Where("status = ? AND (started_at IS NULL OR started_at <= ?)", models.ImageVariantStatusRunning, staleBefore).
			Updates(map[string]interface{}{
				"status":          models.ImageVariantStatusFailed,
				"next_attempt_at": now,
				"last_error":      "worker lease expired",
				"started_at":      nil,
			}).Error; err != nil {
			return err
		}
		query := tx.Where(
			"attempts < ? AND (status = ? OR (status = ? AND next_attempt_at IS NOT NULL AND next_attempt_at <= ?))",
			worker.maxAttempts,
			models.ImageVariantStatusPending,
			models.ImageVariantStatusFailed,
			now,
		).Order("created_at ASC, id ASC")
		if tx.Dialector.Name() == "postgres" {
			query = query.Clauses(clause.Locking{Strength: "UPDATE", Options: "SKIP LOCKED"})
		}
		if err := query.First(&job).Error; err != nil {
			if errors.Is(err, gorm.ErrRecordNotFound) {
				return nil
			}
			return err
		}

		result := tx.Model(&models.ImageVariant{}).
			Where(
				"id = ? AND attempts < ? AND (status = ? OR (status = ? AND next_attempt_at IS NOT NULL AND next_attempt_at <= ?))",
				job.ID,
				worker.maxAttempts,
				models.ImageVariantStatusPending,
				models.ImageVariantStatusFailed,
				now,
			).
			Updates(map[string]interface{}{
				"status":          models.ImageVariantStatusRunning,
				"attempts":        gorm.Expr("attempts + 1"),
				"next_attempt_at": nil,
				"started_at":      now,
				"last_error":      "",
			})
		if result.Error != nil {
			return result.Error
		}
		if result.RowsAffected != 1 {
			return nil
		}
		job.Status = models.ImageVariantStatusRunning
		job.Attempts++
		job.NextAttemptAt = nil
		startedAt := now
		job.StartedAt = &startedAt
		job.LastError = ""
		found = true
		return nil
	})
	if err != nil && worker.db.Dialector.Name() == "sqlite" && isSQLiteBusyError(err) {
		return models.ImageVariant{}, false, nil
	}
	if err != nil {
		return models.ImageVariant{}, false, err
	}
	return job, found, nil
}

func isSQLiteBusyError(err error) bool {
	message := strings.ToLower(err.Error())
	return strings.Contains(message, "database is locked") || strings.Contains(message, "database table is locked") || strings.Contains(message, "database is busy")
}

func (worker *ImageVariantWorker) generate(job models.ImageVariant) error {
	var file models.File
	if err := worker.db.First(&file, job.FileID).Error; err != nil {
		return fmt.Errorf("读取原图记录失败: %w", err)
	}
	if file.AccessScope != models.FileAccessPublic {
		return fmt.Errorf("原图不再公开")
	}
	if file.MimeType != job.MimeType {
		return fmt.Errorf("原图 MIME 与任务不一致")
	}
	expectedPath, ok := ImageVariantPath(file.Path, file.MimeType, job.Variant)
	if !ok || expectedPath != job.Path || job.RecipeVersion != ImageVariantRecipeVersion {
		return fmt.Errorf("变体任务配方无效")
	}
	maxDimension, quality, ok := imageVariantRecipe(job.Variant)
	if !ok {
		return fmt.Errorf("不支持的变体类型: %s", job.Variant)
	}

	sourcePath, err := ResolveUploadPath(worker.uploadDir, file.Path)
	if err != nil {
		return fmt.Errorf("原图路径无效: %w", err)
	}
	source, err := os.Open(sourcePath)
	if err != nil {
		return fmt.Errorf("读取原图失败: %w", err)
	}
	defer source.Close()
	header := make([]byte, 512)
	n, _ := io.ReadFull(source, header)
	if _, err := source.Seek(0, io.SeekStart); err != nil {
		return fmt.Errorf("重置原图读取位置失败: %w", err)
	}
	if actualMime := http.DetectContentType(header[:n]); actualMime != file.MimeType {
		return fmt.Errorf("原图 MIME 校验失败: %s", actualMime)
	}
	decoded, _, err := image.Decode(source)
	if err != nil {
		return fmt.Errorf("解码原图失败: %w", err)
	}
	bounds := decoded.Bounds()
	if bounds.Dx() <= 0 || bounds.Dy() <= 0 {
		return fmt.Errorf("原图尺寸无效")
	}
	targetWidth, targetHeight := scaledImageSize(bounds.Dx(), bounds.Dy(), maxDimension)
	resized := image.NewNRGBA(image.Rect(0, 0, targetWidth, targetHeight))
	xdraw.CatmullRom.Scale(resized, resized.Bounds(), decoded, bounds, xdraw.Over, nil)

	destinationPath, err := ResolveUploadPath(worker.uploadDir, job.Path)
	if err != nil {
		return fmt.Errorf("变体路径无效: %w", err)
	}
	if err := os.MkdirAll(filepath.Dir(destinationPath), 0755); err != nil {
		return fmt.Errorf("创建变体目录失败: %w", err)
	}
	temporary, err := os.CreateTemp(filepath.Dir(destinationPath), ".image-variant-*")
	if err != nil {
		return fmt.Errorf("创建变体临时文件失败: %w", err)
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)
	if err := encodeImageVariant(temporary, file.MimeType, resized, quality); err != nil {
		_ = temporary.Close()
		return err
	}
	if err := temporary.Sync(); err != nil {
		_ = temporary.Close()
		return fmt.Errorf("同步变体临时文件失败: %w", err)
	}
	if err := temporary.Close(); err != nil {
		return fmt.Errorf("关闭变体临时文件失败: %w", err)
	}
	metadata, err := validateImageVariantOutput(temporaryPath, file.MimeType, targetWidth, targetHeight)
	if err != nil {
		return err
	}
	if err := os.Rename(temporaryPath, destinationPath); err != nil {
		return fmt.Errorf("原子发布变体失败: %w", err)
	}
	if err := syncDirectory(filepath.Dir(destinationPath)); err != nil {
		return fmt.Errorf("同步变体目录失败: %w", err)
	}
	job.Width = metadata.Width
	job.Height = metadata.Height
	job.Size = metadata.Size
	return worker.persistGeneratedMetadata(job)
}

func imageVariantRecipe(variant string) (maxDimension, quality int, ok bool) {
	switch variant {
	case ImageVariantThumb:
		return 480, 80, true
	case ImageVariantMedium:
		return 1280, 84, true
	default:
		return 0, 0, false
	}
}

func scaledImageSize(width, height, maxDimension int) (int, int) {
	if width <= maxDimension && height <= maxDimension {
		return width, height
	}
	scale := float64(maxDimension) / float64(max(width, height))
	return max(1, int(float64(width)*scale)), max(1, int(float64(height)*scale))
}

func encodeImageVariant(output *os.File, mimeType string, imageValue image.Image, quality int) error {
	var err error
	switch mimeType {
	case "image/jpeg":
		err = jpeg.Encode(output, imageValue, &jpeg.Options{Quality: quality})
	case "image/png":
		err = png.Encode(output, imageValue)
	default:
		return fmt.Errorf("不支持生成变体的 MIME: %s", mimeType)
	}
	if err != nil {
		return fmt.Errorf("编码变体失败: %w", err)
	}
	return nil
}

type imageVariantOutputMetadata struct {
	Width  int
	Height int
	Size   int64
}

func validateImageVariantOutput(filename, expectedMime string, expectedWidth, expectedHeight int) (imageVariantOutputMetadata, error) {
	file, err := os.Open(filename)
	if err != nil {
		return imageVariantOutputMetadata{}, err
	}
	defer file.Close()
	header := make([]byte, 512)
	n, _ := io.ReadFull(file, header)
	if actualMime := http.DetectContentType(header[:n]); actualMime != expectedMime {
		return imageVariantOutputMetadata{}, fmt.Errorf("变体 MIME 校验失败: %s", actualMime)
	}
	if _, err := file.Seek(0, io.SeekStart); err != nil {
		return imageVariantOutputMetadata{}, err
	}
	config, _, err := image.DecodeConfig(file)
	if err != nil {
		return imageVariantOutputMetadata{}, fmt.Errorf("变体尺寸校验失败: %w", err)
	}
	if config.Width != expectedWidth || config.Height != expectedHeight {
		return imageVariantOutputMetadata{}, fmt.Errorf("变体尺寸不匹配: %dx%d", config.Width, config.Height)
	}
	info, err := file.Stat()
	if err != nil || info.Size() <= 0 {
		return imageVariantOutputMetadata{}, fmt.Errorf("变体文件大小无效: %w", err)
	}
	return imageVariantOutputMetadata{Width: config.Width, Height: config.Height, Size: info.Size()}, nil
}

func syncDirectory(directory string) error {
	if runtime.GOOS == "windows" {
		return nil
	}
	file, err := os.Open(directory)
	if err != nil {
		return err
	}
	defer file.Close()
	return file.Sync()
}

func (worker *ImageVariantWorker) persistGeneratedMetadata(job models.ImageVariant) error {
	result := worker.db.Model(&models.ImageVariant{}).
		Where("id = ? AND status = ? AND attempts = ?", job.ID, models.ImageVariantStatusRunning, job.Attempts).
		Updates(map[string]interface{}{
			"width":  job.Width,
			"height": job.Height,
			"size":   job.Size,
		})
	if result.Error != nil {
		return result.Error
	}
	if result.RowsAffected != 1 {
		return fmt.Errorf("变体任务状态已变化")
	}
	return nil
}

func (worker *ImageVariantWorker) markReady(job models.ImageVariant) error {
	result := worker.db.Model(&models.ImageVariant{}).
		Where("id = ? AND status = ? AND attempts = ?", job.ID, models.ImageVariantStatusRunning, job.Attempts).
		Updates(map[string]interface{}{
			"status":          models.ImageVariantStatusReady,
			"next_attempt_at": nil,
			"started_at":      nil,
			"last_error":      "",
		})
	if result.Error != nil {
		return result.Error
	}
	if result.RowsAffected != 1 {
		return fmt.Errorf("变体任务无法标记为 ready")
	}
	return nil
}

func (worker *ImageVariantWorker) markFailed(job models.ImageVariant, cause error) error {
	message := cause.Error()
	if len(message) > 2000 {
		message = message[:2000]
	}
	var nextAttemptAt *time.Time
	if job.Attempts < worker.maxAttempts {
		next := worker.now().Add(imageVariantRetryBackoff(job.Attempts))
		nextAttemptAt = &next
	}
	result := worker.db.Model(&models.ImageVariant{}).
		Where("id = ? AND status = ? AND attempts = ?", job.ID, models.ImageVariantStatusRunning, job.Attempts).
		Updates(map[string]interface{}{
			"status":          models.ImageVariantStatusFailed,
			"next_attempt_at": nextAttemptAt,
			"started_at":      nil,
			"last_error":      message,
		})
	if result.Error != nil {
		return result.Error
	}
	if result.RowsAffected != 1 {
		return fmt.Errorf("变体任务无法标记为 failed")
	}
	return nil
}

func imageVariantRetryBackoff(attempt int) time.Duration {
	if attempt <= 1 {
		return time.Second
	}
	delay := time.Second << min(attempt-1, 6)
	if delay > time.Minute {
		return time.Minute
	}
	return delay
}
