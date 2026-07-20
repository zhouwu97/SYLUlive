BEGIN;

CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

ALTER TABLE ai_knowledge_documents
    ADD COLUMN IF NOT EXISTS source_file_name VARCHAR(255) NOT NULL DEFAULT '',
    ADD COLUMN IF NOT EXISTS document_type VARCHAR(64) NOT NULL DEFAULT '',
    ADD COLUMN IF NOT EXISTS department VARCHAR(255) NOT NULL DEFAULT '',
    ADD COLUMN IF NOT EXISTS effective_from TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS effective_to TIMESTAMPTZ;

ALTER TABLE ai_knowledge_chunks
    ADD COLUMN IF NOT EXISTS search_tokens TEXT NOT NULL DEFAULT '',
    ADD COLUMN IF NOT EXISTS page_number INTEGER,
    ADD COLUMN IF NOT EXISTS section_title VARCHAR(500) NOT NULL DEFAULT '',
    ADD COLUMN IF NOT EXISTS source_locator VARCHAR(500) NOT NULL DEFAULT '',
    ADD COLUMN IF NOT EXISTS embedding_model_version VARCHAR(100) NOT NULL DEFAULT 'legacy-1536';

CREATE INDEX IF NOT EXISTS idx_ai_knowledge_chunks_fts
    ON ai_knowledge_chunks USING gin (to_tsvector('simple', search_tokens || ' ' || content));
CREATE INDEX IF NOT EXISTS idx_ai_knowledge_chunks_trgm
    ON ai_knowledge_chunks USING gin (content gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_ai_knowledge_documents_effective
    ON ai_knowledge_documents(status, effective_from, effective_to);

CREATE TABLE IF NOT EXISTS ai_embedding_model_registry (
    version VARCHAR(100) PRIMARY KEY,
    model_name VARCHAR(255) NOT NULL,
    dimensions INTEGER NOT NULL CHECK (dimensions = 1536),
    active BOOLEAN NOT NULL DEFAULT FALSE,
    activated_at TIMESTAMPTZ,
    rollback_until TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_ai_embedding_one_active
    ON ai_embedding_model_registry(active) WHERE active = TRUE;

CREATE TABLE IF NOT EXISTS ai_knowledge_ingestion_jobs (
    id VARCHAR(36) PRIMARY KEY,
    document_id BIGINT NOT NULL REFERENCES ai_knowledge_documents(id) ON DELETE CASCADE,
    status VARCHAR(24) NOT NULL,
    restore_status VARCHAR(24) NOT NULL DEFAULT 'inspected',
    attempt INTEGER NOT NULL DEFAULT 0,
    error_code VARCHAR(64) NOT NULL DEFAULT '',
    error_detail VARCHAR(500) NOT NULL DEFAULT '',
    not_before TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    started_at TIMESTAMPTZ,
    completed_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_ai_ingestion_jobs_poll
    ON ai_knowledge_ingestion_jobs(status, not_before, created_at);

CREATE TABLE IF NOT EXISTS ai_conversations (
    id VARCHAR(36) PRIMARY KEY,
    user_id BIGINT NOT NULL,
    title VARCHAR(80) NOT NULL DEFAULT '',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_ai_conversations_user_updated
    ON ai_conversations(user_id, updated_at DESC) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS ai_runs (
    id VARCHAR(36) PRIMARY KEY,
    user_id BIGINT NOT NULL,
    conversation_id VARCHAR(36) NOT NULL REFERENCES ai_conversations(id) ON DELETE CASCADE,
    client_request_id VARCHAR(36) NOT NULL,
    state VARCHAR(32) NOT NULL,
    state_version BIGINT NOT NULL DEFAULT 0,
    provider VARCHAR(32) NOT NULL,
    model VARCHAR(100) NOT NULL,
    attempt INTEGER NOT NULL DEFAULT 1,
    message_hash VARCHAR(64) NOT NULL,
    message_length INTEGER NOT NULL,
    budget_reservation_id VARCHAR(36),
    last_event_seq BIGINT NOT NULL DEFAULT 0,
    answer_checkpoint TEXT NOT NULL DEFAULT '',
    error_code VARCHAR(64) NOT NULL DEFAULT '',
    cancelled_at TIMESTAMPTZ,
    expires_at TIMESTAMPTZ NOT NULL,
    started_at TIMESTAMPTZ,
    completed_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(user_id, client_request_id)
);
CREATE INDEX IF NOT EXISTS idx_ai_runs_user_created ON ai_runs(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_ai_runs_state_expires ON ai_runs(state, expires_at);

CREATE TABLE IF NOT EXISTS ai_conversation_messages (
    id VARCHAR(36) PRIMARY KEY,
    conversation_id VARCHAR(36) NOT NULL REFERENCES ai_conversations(id) ON DELETE CASCADE,
    run_id VARCHAR(36) REFERENCES ai_runs(id) ON DELETE CASCADE,
    role VARCHAR(16) NOT NULL,
    content TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_ai_messages_conversation_created
    ON ai_conversation_messages(conversation_id, created_at, id);

CREATE TABLE IF NOT EXISTS ai_events (
    id BIGSERIAL PRIMARY KEY,
    run_id VARCHAR(36) NOT NULL REFERENCES ai_runs(id) ON DELETE CASCADE,
    seq BIGINT NOT NULL,
    type VARCHAR(48) NOT NULL,
    payload JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(run_id, seq)
);

CREATE TABLE IF NOT EXISTS ai_tool_calls (
    call_id VARCHAR(100) PRIMARY KEY,
    run_id VARCHAR(36) NOT NULL REFERENCES ai_runs(id) ON DELETE CASCADE,
    user_id BIGINT NOT NULL,
    tool_name VARCHAR(100) NOT NULL,
    tool_version VARCHAR(32) NOT NULL,
    arguments_json JSONB NOT NULL,
    arguments_hash VARCHAR(64) NOT NULL,
    status VARCHAR(24) NOT NULL,
    state_version BIGINT NOT NULL DEFAULT 0,
    expires_at TIMESTAMPTZ NOT NULL,
    result_json JSONB,
    result_hash VARCHAR(64) NOT NULL DEFAULT '',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    completed_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_ai_tool_calls_run ON ai_tool_calls(run_id, created_at);

CREATE TABLE IF NOT EXISTS ai_quota_entries (
    id BIGSERIAL PRIMARY KEY,
    user_id BIGINT NOT NULL,
    run_id VARCHAR(36) NOT NULL UNIQUE,
    status VARCHAR(16) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    released_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_ai_quota_user_created
    ON ai_quota_entries(user_id, created_at DESC) WHERE status IN ('reserved', 'consumed');

CREATE TABLE IF NOT EXISTS ai_user_budgets (
    user_id BIGINT PRIMARY KEY,
    limit_micro_yuan BIGINT NOT NULL CHECK (limit_micro_yuan >= 0),
    used_micro_yuan BIGINT NOT NULL DEFAULT 0 CHECK (used_micro_yuan >= 0),
    reserved_micro_yuan BIGINT NOT NULL DEFAULT 0 CHECK (reserved_micro_yuan >= 0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS ai_budget_reservations (
    id VARCHAR(36) PRIMARY KEY,
    run_id VARCHAR(36) NOT NULL UNIQUE REFERENCES ai_runs(id) ON DELETE CASCADE,
    user_id BIGINT NOT NULL,
    reserved_micro_yuan BIGINT NOT NULL CHECK (reserved_micro_yuan >= 0),
    actual_micro_yuan BIGINT NOT NULL DEFAULT 0 CHECK (actual_micro_yuan >= 0),
    status VARCHAR(16) NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    settled_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_ai_budget_reservations_expiry
    ON ai_budget_reservations(status, expires_at);

CREATE TABLE IF NOT EXISTS ai_usage_records (
    id BIGSERIAL PRIMARY KEY,
    run_id VARCHAR(36) NOT NULL UNIQUE REFERENCES ai_runs(id) ON DELETE CASCADE,
    user_hash VARCHAR(64) NOT NULL,
    provider VARCHAR(32) NOT NULL,
    model VARCHAR(100) NOT NULL,
    input_tokens INTEGER NOT NULL DEFAULT 0,
    output_tokens INTEGER NOT NULL DEFAULT 0,
    cache_hit_tokens INTEGER NOT NULL DEFAULT 0,
    cost_micro_yuan BIGINT NOT NULL DEFAULT 0,
    latency_milliseconds BIGINT NOT NULL DEFAULT 0,
    error_class VARCHAR(64) NOT NULL DEFAULT '',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_ai_usage_created ON ai_usage_records(created_at DESC);

CREATE TABLE IF NOT EXISTS class_period_profiles (
    id BIGSERIAL PRIMARY KEY,
    academic_year VARCHAR(20) NOT NULL,
    name VARCHAR(100) NOT NULL,
    status VARCHAR(20) NOT NULL,
    periods JSONB NOT NULL,
    effective_from TIMESTAMPTZ NOT NULL,
    effective_to TIMESTAMPTZ NOT NULL,
    created_by BIGINT NOT NULL,
    published_by BIGINT NOT NULL DEFAULT 0,
    published_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_class_period_profiles_lookup
    ON class_period_profiles(academic_year, status, effective_from, effective_to);
CREATE UNIQUE INDEX IF NOT EXISTS idx_class_period_profiles_one_published
    ON class_period_profiles(academic_year) WHERE status = 'published';

COMMIT;
