BEGIN;

-- 旧列继续用于二进制回滚，但新入库不再把低维向量补零写成 vector(1536)。
ALTER TABLE ai_knowledge_chunks
    ALTER COLUMN embedding DROP NOT NULL;

ALTER TABLE ai_embedding_model_registry
    DROP CONSTRAINT IF EXISTS ai_embedding_model_registry_dimensions_check;
ALTER TABLE ai_embedding_model_registry
    ADD CONSTRAINT ai_embedding_model_registry_dimensions_check
    CHECK (dimensions BETWEEN 1 AND 2000);

-- 先登记历史模型，确保迁移可以覆盖早期仅写 chunk 版本字段的数据。
INSERT INTO ai_embedding_model_registry (version, model_name, dimensions, active, created_at)
SELECT DISTINCT embedding_model_version, embedding_model_version, 1536, FALSE, NOW()
FROM ai_knowledge_chunks
WHERE embedding_model_version <> ''
ON CONFLICT (version) DO NOTHING;

CREATE TABLE IF NOT EXISTS ai_knowledge_chunk_embeddings (
    id BIGSERIAL PRIMARY KEY,
    chunk_id BIGINT NOT NULL REFERENCES ai_knowledge_chunks(id) ON DELETE CASCADE,
    model_version VARCHAR(100) NOT NULL REFERENCES ai_embedding_model_registry(version),
    dimensions INTEGER NOT NULL CHECK (dimensions BETWEEN 1 AND 2000),
    embedding vector NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT ck_ai_chunk_embedding_real_dimensions
        CHECK (vector_dims(embedding) = dimensions),
    UNIQUE (chunk_id, model_version)
);

-- 历史 1536 列数据按原版本标识迁入，仅用于兼容旧索引；不得改名伪装成新的真实维度模型。
INSERT INTO ai_knowledge_chunk_embeddings (chunk_id, model_version, dimensions, embedding, created_at)
SELECT id, embedding_model_version, 1536, embedding, created_at
FROM ai_knowledge_chunks
WHERE embedding IS NOT NULL AND embedding_model_version <> ''
ON CONFLICT (chunk_id, model_version) DO NOTHING;

CREATE INDEX IF NOT EXISTS idx_ai_chunk_embeddings_model_dimensions
    ON ai_knowledge_chunk_embeddings(model_version, dimensions, chunk_id);
CREATE INDEX IF NOT EXISTS idx_ai_chunk_embeddings_hnsw_384
    ON ai_knowledge_chunk_embeddings
    USING hnsw ((embedding::vector(384)) vector_cosine_ops)
    WHERE dimensions = 384;
CREATE INDEX IF NOT EXISTS idx_ai_chunk_embeddings_hnsw_1536
    ON ai_knowledge_chunk_embeddings
    USING hnsw ((embedding::vector(1536)) vector_cosine_ops)
    WHERE dimensions = 1536;

COMMIT;
