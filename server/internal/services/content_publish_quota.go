package services

import (
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	"gorm.io/gorm"
	"gorm.io/gorm/clause"

	"shenliyuan/internal/models"
)

// 内容发布额度的窗口与阈值。
//
// 这些是“成功发表计数”，不是自然日配额；窗口左右边界统一为
// `created_at > now-window AND created_at <= now`，因此刚好位于窗口起点的记录
// 不再占用额度，窗口到期后会自然恢复。
const (
	PostPublishShortWindow = 5 * time.Minute
	PostPublishShortLimit  = 6
	PostPublishLongWindow  = 24 * time.Hour
	PostPublishLongLimit   = 30

	ReplyPublishShortWindow = 10 * time.Minute
	ReplyPublishShortLimit  = 30
	ReplyPublishLongWindow  = 24 * time.Hour
	ReplyPublishLongLimit   = 200
	// ReplyDuplicateWindow 是同一账号在同一帖子下重复文本的判定窗口。
	ReplyDuplicateWindow = time.Minute
)

var (
	// ErrContentRateLimited 表示成功发表额度已满（对应 429）。
	ErrContentRateLimited = errors.New("content_rate_limited")
	// ErrContentDuplicate 表示同一分钟内在同一帖子重复发表相同文本（对应 429）。
	ErrContentDuplicate = errors.New("content_duplicate")
	// ErrContentQuotaUnavailable 表示额度查询/加锁/存储暂不可用（对应 503）。
	// 它不等于用户违规，不触发登出、封号或积分处罚；调用方也不能把它当作“0 次”放行。
	ErrContentQuotaUnavailable = errors.New("content_quota_unavailable")
)

// contentWriteSerialLock 仅为 SQLite 测试环境提供与 PostgreSQL 行锁等价的串行语义。
// 它不构成多进程/多实例的正确性证明：生产正确性来自事务内的用户行锁 + 数据库原子 UPSERT。
var contentWriteSerialLock sync.Mutex

// AcquireContentWriteSerialLock 在非 PostgreSQL（拨号器无行锁能力）环境下串行化写入。
// 调用方应在事务之前获取、事务结束之后释放；PostgreSQL 下是空操作。
func AcquireContentWriteSerialLock(db *gorm.DB) func() {
	if db == nil || db.Dialector == nil || db.Dialector.Name() != "sqlite" {
		return func() {}
	}
	contentWriteSerialLock.Lock()
	return contentWriteSerialLock.Unlock
}

// LockUserForContentWrite 在事务内锁定发布用户行，把“额度检查 + 内容创建”串成
// 一个不可交错的临界区，避免并发请求各自读到未提交状态后一起放行。
//
// 使用 FOR NO KEY UPDATE：它与 FOR UPDATE / FOR NO KEY UPDATE 互斥，足以串行化
// 同一账号的内容写入，同时避免不必要地阻塞仅持有外键键共享锁的路径。
//
// 关键约束：所有消耗同一配额的创建入口（普通发帖、组队招募、投票）都必须调用本
// 函数，否则行锁无法覆盖整个配额域。等待锁之后才允许执行计数查询——READ COMMITTED
// 下计数查询才会看到此前已提交的内容。
func LockUserForContentWrite(tx *gorm.DB, userID uint) error {
	if tx == nil || userID == 0 {
		return fmt.Errorf("%w: 缺少发布用户", ErrContentQuotaUnavailable)
	}
	var user models.User
	query := tx.Clauses(clause.Locking{Strength: "NO KEY UPDATE"}).Select("id")
	if err := query.First(&user, userID).Error; err != nil {
		return fmt.Errorf("%w: 锁定发布用户失败: %v", ErrContentQuotaUnavailable, err)
	}
	return nil
}

// LockPostStatusForReply 在同一事务内对目标帖子行加行锁并返回其当前状态。
// 治理（隐藏/删除）在 PostgreSQL 上也会更新同一行，"复核 + 写入回复"必须与治理串行化，
// 否则复核读到 normal 之后治理立即隐藏，事务仍会把回复提交到已不可回复的帖子上。
// SQLite 无行锁语义，此处依赖调用方 AcquireContentWriteSerialLock 提供的进程内串行。
func LockPostStatusForReply(tx *gorm.DB, postID uint) (models.PostStatus, error) {
	if tx == nil || postID == 0 {
		return "", fmt.Errorf("%w: 缺少目标帖子", ErrContentQuotaUnavailable)
	}
	var post models.Post
	if err := tx.Clauses(clause.Locking{Strength: "NO KEY UPDATE"}).Select("id", "status").First(&post, postID).Error; err != nil {
		return "", err
	}
	return post.Status, nil
}

// CheckPostPublishQuota 在同一事务内检查发帖额度。
// 失败路径不区分“额度已满”和“查询不可用”：前者是用户可见的 429，后者是 503。
func CheckPostPublishQuota(tx *gorm.DB, userID uint, now time.Time) error {
	if tx == nil {
		return fmt.Errorf("%w: 缺少事务", ErrContentQuotaUnavailable)
	}
	if count, err := countPostsInWindow(tx, userID, now.Add(-PostPublishShortWindow), now); err != nil {
		return err
	} else if count >= PostPublishShortLimit {
		return ErrContentRateLimited
	}
	if count, err := countPostsInWindow(tx, userID, now.Add(-PostPublishLongWindow), now); err != nil {
		return err
	} else if count >= PostPublishLongLimit {
		return ErrContentRateLimited
	}
	return nil
}

func countPostsInWindow(tx *gorm.DB, userID uint, start, end time.Time) (int64, error) {
	var count int64
	if err := tx.Model(&models.Post{}).
		Where("author_id = ? AND created_at > ? AND created_at <= ?", userID, start, end).
		Count(&count).Error; err != nil {
		return 0, fmt.Errorf("%w: 发帖额度查询失败: %v", ErrContentQuotaUnavailable, err)
	}
	return count, nil
}

// CheckReplyPublishQuota 在同一事务内检查回复额度与重复文本。
//
// 纯贴图 / 表情回复同样计入时间额度（content 为空不等于跳过所有限流）；只有
// “真实文本内容”才参与 1 分钟重复判定，避免把不同贴图的兼容占位文本误判为相同内容。
// 媒体相似度与图片识别去重不在本轮范围内。
func CheckReplyPublishQuota(tx *gorm.DB, userID, postID uint, content string, now time.Time) error {
	if tx == nil {
		return fmt.Errorf("%w: 缺少事务", ErrContentQuotaUnavailable)
	}
	var recent int64
	if err := tx.Model(&models.Reply{}).
		Where("author_id = ? AND created_at > ? AND created_at <= ?", userID, now.Add(-ReplyPublishShortWindow), now).
		Count(&recent).Error; err != nil {
		return fmt.Errorf("%w: 回复额度查询失败: %v", ErrContentQuotaUnavailable, err)
	}
	if recent >= ReplyPublishShortLimit {
		return ErrContentRateLimited
	}

	var daily int64
	if err := tx.Model(&models.Reply{}).
		Where("author_id = ? AND created_at > ? AND created_at <= ?", userID, now.Add(-ReplyPublishLongWindow), now).
		Count(&daily).Error; err != nil {
		return fmt.Errorf("%w: 回复额度查询失败: %v", ErrContentQuotaUnavailable, err)
	}
	if daily >= ReplyPublishLongLimit {
		return ErrContentRateLimited
	}

	// 只对真实文本内容做重复判定：使用与持久化一致的规范化文本（已 TrimSpace）。
	if normalized := strings.TrimSpace(content); normalized != "" {
		var duplicate int64
		if err := tx.Model(&models.Reply{}).
			Where("author_id = ? AND post_id = ? AND content = ? AND created_at > ? AND created_at <= ?",
				userID, postID, normalized, now.Add(-ReplyDuplicateWindow), now).
			Count(&duplicate).Error; err != nil {
			return fmt.Errorf("%w: 重复回复查询失败: %v", ErrContentQuotaUnavailable, err)
		}
		if duplicate > 0 {
			return ErrContentDuplicate
		}
	}
	return nil
}
