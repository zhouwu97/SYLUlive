package services

import (
	"context"
	"errors"
	"fmt"
	"log"
	"os"
	"sync"
	"time"

	"gorm.io/gorm"
	"gorm.io/gorm/clause"

	"shenliyuan/internal/models"
)

var (
	// ErrUploadQuotaExceeded 表示账号或服务级临时上传额度已用尽。
	ErrUploadQuotaExceeded = errors.New("upload quota exceeded")
	// ErrUploadStoragePressure 表示所在文件系统达到上传熔断水位。
	ErrUploadStoragePressure = errors.New("upload storage pressure")
	// ErrUploadProtectionUnavailable 表示额度/容量检查无法可靠完成。
	ErrUploadProtectionUnavailable = errors.New("upload protection unavailable")
)

const uploadQuotaAdvisoryLockKey int64 = 0x53594c55504c44

var uploadQuotaSQLiteLock sync.Mutex

func lockUploadHash(tx *gorm.DB, hash string) error {
	if tx.Dialector != nil && tx.Dialector.Name() == "postgres" {
		if err := tx.Exec("SELECT pg_advisory_xact_lock(hashtextextended(?, 0))", hash).Error; err != nil {
			return fmt.Errorf("%w: 锁定文件哈希失败: %v", ErrUploadProtectionUnavailable, err)
		}
	}
	return nil
}

// UploadProtectionConfig 集中描述上传接口的资源上限。所有字节字段均为字节数。
type UploadProtectionConfig struct {
	PerMinuteCountLimit   int
	HourlyBytesLimit      int64
	TemporaryUserCount    int
	TemporaryUserBytes    int64
	TemporaryGlobalBytes  int64
	DiskWarnPercent       int
	DiskSeverePercent     int
	DiskCriticalPercent   int
	FailClosedOnDiskCheck bool
}

// DefaultUploadProtectionConfig 是生产环境的保守默认值，可用环境变量按实际业务调整。
func DefaultUploadProtectionConfig() UploadProtectionConfig {
	return UploadProtectionConfig{
		PerMinuteCountLimit:  30,
		HourlyBytesLimit:     100 * 1024 * 1024,
		TemporaryUserCount:   100,
		TemporaryUserBytes:   512 * 1024 * 1024,
		TemporaryGlobalBytes: 5 * 1024 * 1024 * 1024,
		DiskWarnPercent:      70,
		DiskSeverePercent:    80,
		DiskCriticalPercent:  90,
	}
}

// Validate 检查配置之间的单调关系，避免错误环境变量使熔断阈值失效。
func (c UploadProtectionConfig) Validate() error {
	if c.PerMinuteCountLimit <= 0 || c.HourlyBytesLimit <= 0 || c.TemporaryUserCount <= 0 || c.TemporaryUserBytes <= 0 || c.TemporaryGlobalBytes <= 0 {
		return fmt.Errorf("上传配额必须为正数")
	}
	if c.DiskWarnPercent < 1 || c.DiskSeverePercent < c.DiskWarnPercent || c.DiskCriticalPercent < c.DiskSeverePercent || c.DiskCriticalPercent > 99 {
		return fmt.Errorf("磁盘水位必须满足 1 <= warning <= severe <= critical <= 99")
	}
	return nil
}

// DiskUsageSnapshot 表示上传目录所在文件系统的容量快照。
type DiskUsageSnapshot struct {
	TotalBytes  uint64
	FreeBytes   uint64
	UsedPercent float64
}

// DiskUsageReader 允许测试注入容量数据，生产环境使用平台实现的 readDiskUsage。
type DiskUsageReader func(path string) (DiskUsageSnapshot, error)

// UploadPersistResult 是一次临时文件落盘和数据库写入的结果。
type UploadPersistResult struct {
	File   models.File
	Reused bool
}

// UploadProtection 将配额、容量熔断和数据库写入放到同一个受控边界内。
type UploadProtection struct {
	db        *gorm.DB
	uploadDir string
	config    UploadProtectionConfig

	diskUsage DiskUsageReader
	now       func() time.Time
	logMu     sync.Mutex
	lastLog   time.Time
}

// NewUploadProtection 创建上传保护服务。
func NewUploadProtection(db *gorm.DB, uploadDir string, config UploadProtectionConfig) *UploadProtection {
	defaults := DefaultUploadProtectionConfig()
	if config.PerMinuteCountLimit == 0 {
		config.PerMinuteCountLimit = defaults.PerMinuteCountLimit
	}
	if config.HourlyBytesLimit == 0 {
		config.HourlyBytesLimit = defaults.HourlyBytesLimit
	}
	if config.TemporaryUserCount == 0 {
		config.TemporaryUserCount = defaults.TemporaryUserCount
	}
	if config.TemporaryUserBytes == 0 {
		config.TemporaryUserBytes = defaults.TemporaryUserBytes
	}
	if config.TemporaryGlobalBytes == 0 {
		config.TemporaryGlobalBytes = defaults.TemporaryGlobalBytes
	}
	if config.DiskWarnPercent == 0 {
		config.DiskWarnPercent = defaults.DiskWarnPercent
	}
	if config.DiskSeverePercent == 0 {
		config.DiskSeverePercent = defaults.DiskSeverePercent
	}
	if config.DiskCriticalPercent == 0 {
		config.DiskCriticalPercent = defaults.DiskCriticalPercent
	}
	return &UploadProtection{
		db:        db,
		uploadDir: uploadDir,
		config:    config,
		diskUsage: readDiskUsage,
		now:       time.Now,
	}
}

// SetDiskUsageReader 仅供测试或受控运行环境替换容量读取器。
func (p *UploadProtection) SetDiskUsageReader(reader DiskUsageReader) {
	if p != nil && reader != nil {
		p.diskUsage = reader
	}
}

// SetNow 让时间窗口测试不依赖真实时钟。
func (p *UploadProtection) SetNow(now func() time.Time) {
	if p != nil && now != nil {
		p.now = now
	}
}

// CheckDisk 在真正写盘前执行容量熔断。发布模式下容量读取失败也拒绝写盘，
// 避免文件系统状态未知时失去磁盘熔断；开发模式仍兼容不支持 statfs 的平台。
func (p *UploadProtection) CheckDisk(ctx context.Context) error {
	if p == nil {
		return nil
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	snapshot, err := p.diskUsage(p.uploadDir)
	if err != nil {
		p.logPressure("unknown", snapshot, err)
		if p.config.FailClosedOnDiskCheck {
			return fmt.Errorf("%w: 无法确认上传目录磁盘容量: %v", ErrUploadProtectionUnavailable, err)
		}
		return nil
	}
	if snapshot.UsedPercent >= float64(p.config.DiskCriticalPercent) {
		p.logPressure("critical", snapshot, nil)
		return fmt.Errorf("%w: 磁盘使用率 %.2f%%", ErrUploadStoragePressure, snapshot.UsedPercent)
	}
	if snapshot.UsedPercent >= float64(p.config.DiskSeverePercent) {
		p.logPressure("severe", snapshot, nil)
	} else if snapshot.UsedPercent >= float64(p.config.DiskWarnPercent) {
		p.logPressure("warning", snapshot, nil)
	}
	return nil
}

func (p *UploadProtection) logPressure(level string, snapshot DiskUsageSnapshot, err error) {
	p.logMu.Lock()
	defer p.logMu.Unlock()
	now := p.now()
	if level != "critical" && now.Sub(p.lastLog) < time.Minute {
		return
	}
	p.lastLog = now
	if err != nil {
		log.Printf("[UPLOAD_DISK_PRESSURE] level=%s path=%s error=%v", level, p.uploadDir, err)
		return
	}
	log.Printf("[UPLOAD_DISK_PRESSURE] level=%s path=%s used=%.2f%% free_bytes=%d", level, p.uploadDir, snapshot.UsedPercent, snapshot.FreeBytes)
}

// CheckQuota 必须在调用方事务中执行。它先锁住用户行，再读取窗口统计，保证多个
// 上传请求不会同时读到旧额度并一起穿透限制。
func (p *UploadProtection) CheckQuota(tx *gorm.DB, userID uint, incomingCount int, incomingBytes int64, now time.Time) error {
	if p == nil || tx == nil || userID == 0 || incomingCount <= 0 || incomingBytes < 0 {
		return fmt.Errorf("%w: 参数无效", ErrUploadProtectionUnavailable)
	}
	if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Select("id").First(&models.User{}, userID).Error; err != nil {
		return fmt.Errorf("%w: 锁定上传用户失败: %v", ErrUploadProtectionUnavailable, err)
	}
	// 用户行锁只能串行化同一账号；全局临时空间还需要一个跨账号的锁。
	// PostgreSQL 使用事务级 advisory lock，SQLite 测试/单进程环境由 PersistTemporaryFile
	// 外层互斥覆盖整个事务。
	if tx.Dialector != nil && tx.Dialector.Name() == "postgres" {
		if err := tx.Exec("SELECT pg_advisory_xact_lock(?)", uploadQuotaAdvisoryLockKey).Error; err != nil {
			return fmt.Errorf("%w: 锁定全局上传额度失败: %v", ErrUploadProtectionUnavailable, err)
		}
	}

	minuteStart := now.Add(-time.Minute)
	var recentCount int64
	if err := tx.Model(&models.File{}).Where("uploader_id = ? AND created_at > ? AND created_at <= ?", userID, minuteStart, now).Count(&recentCount).Error; err != nil {
		return fmt.Errorf("%w: 查询分钟上传次数失败: %v", ErrUploadProtectionUnavailable, err)
	}
	if recentCount+int64(incomingCount) > int64(p.config.PerMinuteCountLimit) {
		return fmt.Errorf("%w: 分钟上传次数超过限制", ErrUploadQuotaExceeded)
	}

	hourStart := now.Add(-time.Hour)
	var hourlyBytes int64
	if err := tx.Model(&models.File{}).Where("uploader_id = ? AND created_at > ? AND created_at <= ?", userID, hourStart, now).Select("COALESCE(SUM(size), 0)").Scan(&hourlyBytes).Error; err != nil {
		return fmt.Errorf("%w: 查询小时上传字节失败: %v", ErrUploadProtectionUnavailable, err)
	}
	if hourlyBytes+incomingBytes > p.config.HourlyBytesLimit {
		return fmt.Errorf("%w: 小时上传字节超过限制", ErrUploadQuotaExceeded)
	}

	var userTemporaryCount int64
	if err := tx.Model(&models.File{}).Where("uploader_id = ? AND status IN ? AND claimed_at IS NULL", userID, []string{models.FileStatusTemporary, models.FileStatusDeleting}).Count(&userTemporaryCount).Error; err != nil {
		return fmt.Errorf("%w: 查询用户临时文件数量失败: %v", ErrUploadProtectionUnavailable, err)
	}
	if userTemporaryCount+int64(incomingCount) > int64(p.config.TemporaryUserCount) {
		return fmt.Errorf("%w: 用户临时文件数量超过限制", ErrUploadQuotaExceeded)
	}

	var userTemporaryBytes int64
	if err := tx.Model(&models.File{}).Where("uploader_id = ? AND status IN ? AND claimed_at IS NULL", userID, []string{models.FileStatusTemporary, models.FileStatusDeleting}).Select("COALESCE(SUM(size), 0)").Scan(&userTemporaryBytes).Error; err != nil {
		return fmt.Errorf("%w: 查询用户临时文件容量失败: %v", ErrUploadProtectionUnavailable, err)
	}
	if userTemporaryBytes+incomingBytes > p.config.TemporaryUserBytes {
		return fmt.Errorf("%w: 用户临时文件容量超过限制", ErrUploadQuotaExceeded)
	}

	var globalTemporaryBytes int64
	if err := tx.Model(&models.File{}).Where("status IN ? AND claimed_at IS NULL", []string{models.FileStatusTemporary, models.FileStatusDeleting}).Select("COALESCE(SUM(size), 0)").Scan(&globalTemporaryBytes).Error; err != nil {
		return fmt.Errorf("%w: 查询全局临时文件容量失败: %v", ErrUploadProtectionUnavailable, err)
	}
	if globalTemporaryBytes+incomingBytes > p.config.TemporaryGlobalBytes {
		return fmt.Errorf("%w: 服务临时文件容量超过限制", ErrUploadQuotaExceeded)
	}
	return nil
}

// PersistTemporaryFile 在持有用户行锁的事务中完成额度检查、物理写入、文件记录和
// grant。这样数据库提交前不会释放额度临界区，多个服务实例也能依赖 PostgreSQL 行锁。
func (p *UploadProtection) PersistTemporaryFile(ctx context.Context, record *models.File, write func() error) (UploadPersistResult, error) {
	if p == nil || p.db == nil || record == nil || write == nil {
		return UploadPersistResult{}, fmt.Errorf("%w: 上传保护未初始化", ErrUploadProtectionUnavailable)
	}
	var result UploadPersistResult
	targetPath := record.Path
	writeAttempted := false
	pathExistedBefore := false
	var unlock func()
	if p.db.Dialector != nil && p.db.Dialector.Name() == "sqlite" {
		uploadQuotaSQLiteLock.Lock()
		unlock = uploadQuotaSQLiteLock.Unlock
		defer unlock()
	}
	err := p.db.WithContext(ctx).Transaction(func(tx *gorm.DB) (txErr error) {
		defer func() {
			if txErr != nil && writeAttempted && !pathExistedBefore {
				if path, pathErr := ResolveUploadPath(p.uploadDir, targetPath); pathErr == nil {
					// SQLite 由外层进程锁保护；PostgreSQL 由 hash advisory lock
					// 保护同一内容的并发请求，避免清理掉其他请求正在写入的同一路径。
					_ = os.Remove(path)
				}
			}
		}()
		if err := lockUploadHash(tx, record.Hash); err != nil {
			return err
		}
		var existing models.File
		err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Where("hash = ?", record.Hash).First(&existing).Error
		if err == nil {
			if existing.Status == models.FileStatusDeleting {
				return fmt.Errorf("%w: 文件正在清理", ErrFileBeingDeleted)
			}
			if err := tx.Clauses(clause.OnConflict{DoNothing: true}).Create(&models.FileUploadGrant{FileID: existing.ID, UserID: record.UploaderID}).Error; err != nil {
				return err
			}
			result = UploadPersistResult{File: existing, Reused: true}
			return nil
		}
		if !errors.Is(err, gorm.ErrRecordNotFound) {
			return err
		}
		if err := p.CheckQuota(tx, record.UploaderID, 1, record.Size, p.now()); err != nil {
			return err
		}
		if err := p.CheckDisk(ctx); err != nil {
			return err
		}
		if path, resolveErr := ResolveUploadPath(p.uploadDir, targetPath); resolveErr == nil {
			if _, statErr := os.Stat(path); statErr == nil {
				pathExistedBefore = true
			} else if !errors.Is(statErr, os.ErrNotExist) {
				pathExistedBefore = true
			}
		}
		writeAttempted = true
		if err := write(); err != nil {
			return err
		}
		createResult := tx.Clauses(clause.OnConflict{Columns: []clause.Column{{Name: "hash"}}, DoNothing: true}).Create(record)
		if createResult.Error != nil {
			return createResult.Error
		}
		if err := tx.Where("hash = ?", record.Hash).First(record).Error; err != nil {
			return err
		}
		if record.Status == models.FileStatusDeleting {
			return fmt.Errorf("%w: 文件正在清理", ErrFileBeingDeleted)
		}
		if err := tx.Clauses(clause.OnConflict{DoNothing: true}).Create(&models.FileUploadGrant{FileID: record.ID, UserID: record.UploaderID}).Error; err != nil {
			return err
		}
		result = UploadPersistResult{File: *record, Reused: createResult.RowsAffected == 0}
		return nil
	})
	if err != nil && writeAttempted && !pathExistedBefore {
		// GORM 可能在 callback 成功后才于 COMMIT 阶段返回错误；此时 callback
		// 内的 defer 已经错过清理窗口，再用同一 hash 锁复核一次数据库再清理。
		if cleanupErr := p.cleanupFailedTemporaryPath(record.Hash, targetPath); cleanupErr != nil {
			log.Printf("[UPLOAD_CLEANUP] 事务失败后的物理文件清理失败: hash=%s error=%v", record.Hash, cleanupErr)
		}
	}
	return result, err
}

// ReuseOrRestoreFile 在同一哈希锁和文件行锁内复用已有文件，或在物理文件
// 缺失时安全恢复。写盘期间 janitor 无法把该记录标记为 deleting，避免恢复文件
// 与隔离删除交叉产生“源路径和 trash 同时存在”的坏状态。
// found=false 表示事务内没有该哈希记录，调用方应继续走新文件配额流程。
func (p *UploadProtection) ReuseOrRestoreFile(ctx context.Context, record *models.File, write func(string) error) (result UploadPersistResult, found bool, err error) {
	if p == nil || p.db == nil || record == nil || write == nil || record.UploaderID == 0 {
		return result, false, fmt.Errorf("%w: 复用上传文件参数无效", ErrUploadProtectionUnavailable)
	}
	writeAttempted := false
	pathExistedBefore := false
	var writtenPath string
	var unlock func()
	if p.db.Dialector != nil && p.db.Dialector.Name() == "sqlite" {
		uploadQuotaSQLiteLock.Lock()
		unlock = uploadQuotaSQLiteLock.Unlock
		defer unlock()
	}
	err = p.db.WithContext(ctx).Transaction(func(tx *gorm.DB) (txErr error) {
		defer func() {
			if txErr != nil && writeAttempted && !pathExistedBefore && writtenPath != "" {
				_ = os.Remove(writtenPath)
			}
		}()
		if err := lockUploadHash(tx, record.Hash); err != nil {
			return err
		}
		var existing models.File
		lookupErr := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Where("hash = ?", record.Hash).First(&existing).Error
		if errors.Is(lookupErr, gorm.ErrRecordNotFound) {
			return nil
		}
		if lookupErr != nil {
			return lookupErr
		}
		found = true
		if existing.Status == models.FileStatusDeleting {
			return fmt.Errorf("%w: 文件正在清理", ErrFileBeingDeleted)
		}
		path, pathErr := ResolveUploadPath(p.uploadDir, existing.Path)
		if pathErr != nil {
			return fmt.Errorf("文件路径记录非法: %w", pathErr)
		}
		info, statErr := os.Stat(path)
		if statErr == nil {
			if info.IsDir() {
				return fmt.Errorf("文件路径指向目录")
			}
			if err := tx.Clauses(clause.OnConflict{DoNothing: true}).Create(&models.FileUploadGrant{FileID: existing.ID, UserID: record.UploaderID}).Error; err != nil {
				return err
			}
			result = UploadPersistResult{File: existing, Reused: true}
			return nil
		}
		if !errors.Is(statErr, os.ErrNotExist) {
			return statErr
		}
		if err := p.CheckDisk(ctx); err != nil {
			return err
		}
		pathExistedBefore = false
		writeAttempted = true
		writtenPath = path
		if err := write(path); err != nil {
			return err
		}
		updates := map[string]interface{}{
			"size":      record.Size,
			"mime_type": record.MimeType,
			"width":     record.Width,
			"height":    record.Height,
		}
		updateResult := tx.Model(&models.File{}).Where("id = ? AND status <> ?", existing.ID, models.FileStatusDeleting).Updates(updates)
		if updateResult.Error != nil {
			return updateResult.Error
		}
		if updateResult.RowsAffected != 1 {
			return fmt.Errorf("%w: 文件状态已变化", ErrFileBeingDeleted)
		}
		existing.Size = record.Size
		existing.MimeType = record.MimeType
		existing.Width = record.Width
		existing.Height = record.Height
		if err := tx.Clauses(clause.OnConflict{DoNothing: true}).Create(&models.FileUploadGrant{FileID: existing.ID, UserID: record.UploaderID}).Error; err != nil {
			return err
		}
		result = UploadPersistResult{File: existing, Reused: false}
		return nil
	})
	return result, found, err
}

func (p *UploadProtection) cleanupFailedTemporaryPath(hash, publicPath string) error {
	return p.db.Transaction(func(tx *gorm.DB) error {
		if err := lockUploadHash(tx, hash); err != nil {
			return err
		}
		var existing models.File
		lookupErr := tx.Where("hash = ?", hash).First(&existing).Error
		if lookupErr == nil {
			return nil
		}
		if !errors.Is(lookupErr, gorm.ErrRecordNotFound) {
			return lookupErr
		}
		path, err := ResolveUploadPath(p.uploadDir, publicPath)
		if err != nil {
			return err
		}
		if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
		return nil
	})
}
