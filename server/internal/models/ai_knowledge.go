package models

import (
	"time"

	"gorm.io/datatypes"
	"gorm.io/gorm"
)

const (
	KnowledgeStatusDraft       = "draft"
	KnowledgeStatusParsing     = "parsing"
	KnowledgeStatusNeedsReview = "needs_review"
	KnowledgeStatusIndexing    = "indexing"
	KnowledgeStatusInspected   = "inspected"
	KnowledgeStatusPublished   = "published"
	KnowledgeStatusRevoked     = "revoked"
	KnowledgeStatusSuperseded  = "superseded"
	KnowledgeStatusFailed      = "failed"
)

// AIKnowledgeDocument 保存知识库文档原文、审核状态与发布链路。
type AIKnowledgeDocument struct {
	ID                 uint           `gorm:"primaryKey" json:"id"`
	Title              string         `gorm:"size:255;not null" json:"title"`
	SourceType         string         `gorm:"size:32;not null" json:"source_type"`
	SourceURI          string         `gorm:"size:1000" json:"source_uri"`
	SourceFileName     string         `gorm:"size:255" json:"source_file_name,omitempty"`
	DocumentType       string         `gorm:"size:64;not null;default:'';index" json:"document_type,omitempty"`
	Department         string         `gorm:"size:255;not null;default:'';index" json:"department,omitempty"`
	Content            string         `gorm:"type:text;not null" json:"-"`
	ContentHash        string         `gorm:"size:64;not null;index" json:"content_hash"`
	Status             string         `gorm:"size:24;not null;index" json:"status"`
	Inspection         string         `gorm:"type:text" json:"inspection,omitempty"`
	EffectiveFrom      *time.Time     `gorm:"index" json:"effective_from,omitempty"`
	EffectiveTo        *time.Time     `gorm:"index" json:"effective_to,omitempty"`
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

// AIKnowledgeChunk 是检索与引用验证的最小证据单元。
type AIKnowledgeChunk struct {
	ID           uint64 `gorm:"primaryKey" json:"id"`
	DocumentID   uint   `gorm:"not null;uniqueIndex:idx_ai_chunks_document_index,priority:1;index" json:"document_id"`
	ChunkIndex   int    `gorm:"not null;uniqueIndex:idx_ai_chunks_document_index,priority:2" json:"chunk_index"`
	Content      string `gorm:"type:text;not null" json:"content"`
	ContentHash  string `gorm:"size:64;not null" json:"content_hash"`
	SearchTokens string `gorm:"type:text;not null;default:''" json:"-"`
	// Embedding 仅保留兼容旧索引；新向量按真实维度写入版本化影子表。
	Embedding             string         `gorm:"type:vector(1536)" json:"-"`
	PageNumber            *int           `json:"page_number,omitempty"`
	SectionTitle          string         `gorm:"size:500;not null;default:''" json:"section_title,omitempty"`
	SourceLocator         string         `gorm:"size:500;not null;default:''" json:"source_locator,omitempty"`
	Metadata              datatypes.JSON `gorm:"type:jsonb;not null;default:'{}'" json:"-"`
	EmbeddingModelVersion string         `gorm:"size:100;not null;index" json:"embedding_model_version"`
	CreatedAt             time.Time      `json:"created_at"`
}

func (AIKnowledgeChunk) TableName() string { return "ai_knowledge_chunks" }

// AIKnowledgeChunkEmbedding 将向量与展示正文分离，允许不同模型维度并存且不伪造补零维度。
type AIKnowledgeChunkEmbedding struct {
	ID           uint64    `gorm:"primaryKey" json:"id"`
	ChunkID      uint64    `gorm:"not null;uniqueIndex:idx_ai_chunk_embedding_version,priority:1;index" json:"chunk_id"`
	ModelVersion string    `gorm:"size:100;not null;uniqueIndex:idx_ai_chunk_embedding_version,priority:2;index" json:"model_version"`
	Dimensions   int       `gorm:"not null;index" json:"dimensions"`
	Embedding    string    `gorm:"type:vector;not null" json:"-"`
	CreatedAt    time.Time `json:"created_at"`
}

func (AIKnowledgeChunkEmbedding) TableName() string { return "ai_knowledge_chunk_embeddings" }

type AIKnowledgeIngestionJob struct {
	ID            string     `gorm:"type:varchar(36);primaryKey" json:"id"`
	DocumentID    uint       `gorm:"not null;index" json:"document_id"`
	Status        string     `gorm:"size:24;not null;index" json:"status"`
	RestoreStatus string     `gorm:"size:24;not null;default:'inspected'" json:"restore_status"`
	Attempt       int        `gorm:"not null;default:0" json:"attempt"`
	ErrorCode     string     `gorm:"size:64;not null;default:''" json:"error_code,omitempty"`
	ErrorDetail   string     `gorm:"size:500;not null;default:''" json:"error_detail,omitempty"`
	NotBefore     time.Time  `gorm:"not null;index" json:"not_before"`
	StartedAt     *time.Time `json:"started_at,omitempty"`
	CompletedAt   *time.Time `json:"completed_at,omitempty"`
	CreatedAt     time.Time  `json:"created_at"`
	UpdatedAt     time.Time  `json:"updated_at"`
}

func (AIKnowledgeIngestionJob) TableName() string { return "ai_knowledge_ingestion_jobs" }

type AIEmbeddingModelRegistry struct {
	Version       string     `gorm:"size:100;primaryKey" json:"version"`
	ModelName     string     `gorm:"size:255;not null" json:"model_name"`
	Dimensions    int        `gorm:"not null" json:"dimensions"`
	Active        bool       `gorm:"not null;default:false;index" json:"active"`
	ActivatedAt   *time.Time `json:"activated_at,omitempty"`
	RollbackUntil *time.Time `json:"rollback_until,omitempty"`
	CreatedAt     time.Time  `json:"created_at"`
}

func (AIEmbeddingModelRegistry) TableName() string { return "ai_embedding_model_registry" }

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
