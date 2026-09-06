BEGIN;

-- 只补充计量字段，保留历史人民币预算流水；历史空明细按原模型和已有用量估算。
ALTER TABLE ai_usage_records
    ADD COLUMN IF NOT EXISTS cache_write_tokens BIGINT NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS model_usage JSONB;

COMMIT;
