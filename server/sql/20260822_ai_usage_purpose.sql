ALTER TABLE ai_usage_records
    ADD COLUMN IF NOT EXISTS purpose VARCHAR(32) NOT NULL DEFAULT 'campus_agent';
CREATE INDEX IF NOT EXISTS idx_ai_usage_records_purpose
    ON ai_usage_records(purpose, created_at);
