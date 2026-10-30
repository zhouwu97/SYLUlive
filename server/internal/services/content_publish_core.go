package services

import (
	"errors"
	"gorm.io/gorm"
	"shenliyuan/internal/models"
	"time"
)

var ErrPostNotReplyable = errors.New("post_not_replyable")

// 调用者持有用户行锁并负责事务；App 与助手复用额度和持久化规则。
func PreparePostPublish(tx *gorm.DB, post *models.Post, now time.Time) error {
	if err := CheckPostPublishQuota(tx, post.AuthorID, now); err != nil {
		return err
	}
	post.CreatedAt, post.LastActivityAt = now, now
	return nil
}

func PrepareReplyPublish(tx *gorm.DB, reply *models.Reply, actualText string, now time.Time) error {
	status, err := LockPostStatusForReply(tx, reply.PostID)
	if err != nil {
		return err
	}
	if status != models.PostStatusNormal {
		return ErrPostNotReplyable
	}
	if err := CheckReplyPublishQuota(tx, reply.AuthorID, reply.PostID, actualText, now); err != nil {
		return err
	}
	reply.CreatedAt = now
	return nil
}

func InsertReplyWithActivity(tx *gorm.DB, reply *models.Reply) error {
	if err := tx.Create(reply).Error; err != nil {
		return err
	}
	result := tx.Model(&models.Post{}).Where("id = ? AND status = ?", reply.PostID, models.PostStatusNormal).Updates(map[string]interface{}{
		"reply_count": gorm.Expr("reply_count + 1"), "last_activity_at": reply.CreatedAt,
	})
	if result.Error != nil {
		return result.Error
	}
	if result.RowsAffected != 1 {
		return ErrPostNotReplyable
	}
	return nil
}
