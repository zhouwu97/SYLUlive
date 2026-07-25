BEGIN;

-- 等待设备、授权或教务刷新期间的短期恢复上下文。
-- 载荷仅服务于恢复当前 Run，终态后由运行时删除。
CREATE TABLE IF NOT EXISTS ai_run_resume_jobs (
    id VARCHAR(36) PRIMARY KEY,
    run_id VARCHAR(36) NOT NULL UNIQUE REFERENCES ai_runs(id) ON DELETE CASCADE,
    user_id BIGINT NOT NULL,
    waiting_state VARCHAR(32) NOT NULL,
    messages_json JSONB NOT NULL,
    pending_tool_calls_json JSONB NOT NULL,
    usage_json JSONB NOT NULL,
    status VARCHAR(24) NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_ai_run_resume_jobs_state_expiry
    ON ai_run_resume_jobs(status, waiting_state, expires_at);
CREATE INDEX IF NOT EXISTS idx_ai_run_resume_jobs_user
    ON ai_run_resume_jobs(user_id, status);

COMMIT;
