CREATE TABLE IF NOT EXISTS ai_run_consents (
    id BIGSERIAL PRIMARY KEY,
    run_id VARCHAR(64) NOT NULL REFERENCES ai_runs(id) ON DELETE CASCADE,
    user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    scope VARCHAR(48) NOT NULL,
    granted BOOLEAN NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_ai_run_consents_run_scope UNIQUE (run_id, scope)
);

CREATE INDEX IF NOT EXISTS idx_ai_run_consents_user_run
    ON ai_run_consents (user_id, run_id);
