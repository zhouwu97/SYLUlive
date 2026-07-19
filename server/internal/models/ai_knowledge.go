package models

import (
	"time"

	"gorm.io/gorm"
)

const (
	KnowledgeStatusDraft      = "draft"
	KnowledgeStatusInspected  = "inspected"
	KnowledgeStatusPublished  = "published"
	KnowledgeStatusRevoked    = "revoked"
	KnowledgeStatusSuperseded = "superseded"
)

// AIKnowledgeDocument 保存知识库文档原文、审核状态与发布链路。
type AIKnowledgeDocument struct {
	ID                 uint           `gorm:"primaryKey" json:"id"`
	Title              string         `gorm:"size:255;not null" json:"title"`
	SourceType         string         `gorm:"size:32;not null" json:"source_type"`
	SourceURI          string         `gorm:"size:1000" json:"source_uri"`
	Content            string         `gorm:"type:text;not null" json:"-"`
	ContentHash        string         `gorm:"size:64;not null;index" json:"content_hash"`
	Status             string         `gorm:"size:24;not null;index" json:"status"`
	Inspection         string         `gorm:"type:text" json:"inspection,omitempty"`
	CreatedBy          uint           `gorm:"not null;index" json:"created_by"`
	ReviewedBy         uint           `gorm:"index" json:"reviewed_by,omitempty"`
	SupersededByID     *uint          `gorm:"index" json:"superseded_by_id,omitempty"`
	ReindexRequestedAt *time.Time     `json:"reindex_requested_at,omitempty"`
	PublishedAt        *time.Time     `json:"published_at,omitempty"`
	RevokedAt          *time.Time     `json:"revoked_at,omitempty"`
	CreatedAt          time.Time      `json:"created_at"`
	UpdatedAt          time.Time      `json:"updated_at"`
	DeletedAt          gorm.DeletedAt `gorm:"index" json:"-"`
}

func (AIKnowledgeDocument) TableName() string { return "ai_knowledge_documents" }

// AIKnowledgeAuditLog 的操作者始终取自认证 Context，不接受请求体覆盖。
type AIKnowledgeAuditLog struct {
	ID          uint      `gorm:"primaryKey" json:"id"`
	DocumentID  uint      `gorm:"not null;index" json:"document_id"`
	ActorUserID uint      `gorm:"not null;index" json:"actor_user_id"`
	ActorRole   string    `gorm:"size:20;not null" json:"actor_role"`
	Action      string    `gorm:"size:32;not null;index" json:"action"`
	Detail      string    `gorm:"type:text" json:"detail,omitempty"`
	CreatedAt   time.Time `json:"created_at"`
}

func (AIKnowledgeAuditLog) TableName() string { return "ai_knowledge_audit_logs" }
