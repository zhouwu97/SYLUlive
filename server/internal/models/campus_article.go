package models

import (
	"time"

	"gorm.io/datatypes"
)

// CampusArticle 校园资讯文章（教务通知/公告）
type CampusArticle struct {
	ID               uint           `gorm:"primaryKey" json:"id"`
	Source           string         `gorm:"size:32;not null;index;uniqueIndex:uidx_campus_source_article" json:"source"`
	Category         string         `gorm:"size:64;not null;index" json:"category"`
	CategorySlug     string         `gorm:"size:32;not null;index" json:"category_slug"`
	CategoryID       string         `gorm:"size:32;not null;uniqueIndex:uidx_campus_source_article" json:"category_id"`
	SourceArticleID  string         `gorm:"size:64;not null;uniqueIndex:uidx_campus_source_article" json:"source_article_id"`
	SourceURL        string         `gorm:"size:2048;not null;uniqueIndex" json:"source_url"`
	Title            string         `gorm:"size:500;not null" json:"title"`
	PublishDate      time.Time      `gorm:"type:date;not null;index" json:"publish_date"`
	AuthorDepartment string         `gorm:"size:128" json:"author_department"`
	ContentHTML      string         `gorm:"type:text" json:"content_html"`
	ContentText      string         `gorm:"type:text" json:"content_text"`
	Attachments      datatypes.JSON `json:"attachments"`
	HasAttachment    bool           `json:"has_attachment"`
	ContentHash      string         `gorm:"size:64;not null" json:"content_hash"`
	IsInitialImport  bool           `json:"is_initial_import"`
	FirstSeenAt      time.Time      `json:"first_seen_at"`
	LastSeenAt       time.Time      `json:"last_seen_at"`
	SourceCrawledAt  time.Time      `json:"source_crawled_at"`
	CreatedAt        time.Time      `json:"created_at"`
	UpdatedAt        time.Time      `json:"updated_at"`
}

func (CampusArticle) TableName() string {
	return "campus_articles"
}

// JWCSyncState 校园资讯同步状态
type JWCSyncState struct {
	ID                  uint       `gorm:"primaryKey" json:"id"`
	Source              string     `gorm:"size:32;uniqueIndex" json:"source"`
	LastAttemptAt       *time.Time `json:"last_attempt_at"`
	LastSuccessAt       *time.Time `json:"last_success_at"`
	LastReconcileAt     *time.Time `json:"last_reconcile_at"`
	LastError           string     `json:"last_error"`
	ConsecutiveFailures int        `json:"consecutive_failures"`
	LastItemCount       int        `json:"last_item_count"`
}

func (JWCSyncState) TableName() string {
	return "jwc_sync_states"
}
