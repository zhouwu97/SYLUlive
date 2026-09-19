package services

import (
	"context"
	"errors"
	"fmt"
	"log"
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

// UploadProtectionConfig 集中描述上传接口的资源上限。所有字节字段均为字节数。
type UploadProtectionConfig struct {
	PerMinuteCountLimit  int
	HourlyBytesLimit     int64
	TemporaryUserCount   int
	TemporaryUserBytes   int64
	TemporaryGlobalBytes int64
	DiskWarnPercent      int
	DiskSeverePercent    int
	DiskCriticalPercent  int
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
	if config.DiskWarnPercent == 0 {
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

// CheckDisk 在真正写盘前执行容量熔断。无法取得容量时记录并放行，避免在不支持
// statfs 的开发平台误伤；生产 Linux 会使用真实文件系统统计。
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
	var unlock func()
	if p.db.Dialector != nil && p.db.Dialector.Name() == "sqlite" {
		uploadQuotaSQLiteLock.Lock()
		unlock = uploadQuotaSQLiteLock.Unlock
		defer unlock()
	}
	err := p.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		var existing models.File
		err := tx.Where("hash = ?", record.Hash).First(&existing).Error
		if err == nil {
			if existing.Status == models.FileStatusDeleting {
				return fmt.Errorf("%w: 文件正在清理", ErrUploadProtectionUnavailable)
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
		if err := write(); err != nil {
			return err
		}
		if err := tx.Clauses(clause.OnConflict{Columns: []clause.Column{{Name: "hash"}}, DoNothing: true}).Create(record).Error; err != nil {
			return err
		}
		if err := tx.Where("hash = ?", record.Hash).First(record).Error; err != nil {
			return err
		}
		if err := tx.Clauses(clause.OnConflict{DoNothing: true}).Create(&models.FileUploadGrant{FileID: record.ID, UserID: record.UploaderID}).Error; err != nil {
			return err
		}
		result = UploadPersistResult{File: *record}
		return nil
	})
	return result, err
}
