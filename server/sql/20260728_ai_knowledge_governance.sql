BEGIN;

-- 发布前必须先清理历史重复项；唯一部分索引用于封闭并发发布竞态。
CREATE UNIQUE INDEX IF NOT EXISTS uq_ai_knowledge_documents_published_hash
    ON ai_knowledge_documents(content_hash)
    WHERE deleted_at IS NULL AND status = 'published';

CREATE INDEX IF NOT EXISTS idx_ai_knowledge_documents_published_type
    ON ai_knowledge_documents(document_type, effective_from, effective_to)
    WHERE deleted_at IS NULL AND status = 'published';

COMMIT;
