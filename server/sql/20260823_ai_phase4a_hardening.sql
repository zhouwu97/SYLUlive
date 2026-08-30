-- Phase 4A 预生产加固：权限版本与 Agent 日历动作幂等迁移预检。
ALTER TABLE ai_user_permissions
    ADD COLUMN IF NOT EXISTS version BIGINT NOT NULL DEFAULT 1;

CREATE TABLE IF NOT EXISTS ai_scoped_grants (
    token_hash VARCHAR(64) PRIMARY KEY,
    run_id VARCHAR(36) NOT NULL,
    user_id BIGINT NOT NULL,
    allowed_json JSONB NOT NULL,
    scopes_json JSONB NOT NULL,
    permission_scope VARCHAR(48) NOT NULL DEFAULT '',
    permission_version BIGINT NOT NULL DEFAULT 0,
    status VARCHAR(16) NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    max_calls INTEGER NOT NULL,
    calls INTEGER NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_ai_scoped_grants_run_status
    ON ai_scoped_grants (run_id, status);
CREATE INDEX IF NOT EXISTS idx_ai_scoped_grants_expiry
    ON ai_scoped_grants (expires_at);

CREATE TABLE IF NOT EXISTS user_calendar_action_migration_conflicts (
    id BIGSERIAL PRIMARY KEY,
    user_id BIGINT NOT NULL,
    source_type VARCHAR(32) NOT NULL,
    source_id VARCHAR(128) NOT NULL,
    duplicate_count INTEGER NOT NULL,
    detected_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    resolved_at TIMESTAMPTZ,
    CONSTRAINT uq_user_calendar_action_migration_conflict
        UNIQUE (user_id, source_type, source_id)
);

-- 只记录冲突，不删除历史事件。正式去重必须由运维按 Action Draft / 审计规则显式完成。
INSERT INTO user_calendar_action_migration_conflicts (user_id, source_type, source_id, duplicate_count)
SELECT user_id, source_type, source_id, COUNT(*)
FROM user_calendar_events
WHERE source_type = 'agent_action' AND NULLIF(BTRIM(source_id), '') IS NOT NULL
GROUP BY user_id, source_type, source_id
HAVING COUNT(*) > 1
ON CONFLICT (user_id, source_type, source_id) DO UPDATE
SET duplicate_count = EXCLUDED.duplicate_count;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM user_calendar_events
        WHERE source_type = 'agent_action' AND NULLIF(BTRIM(source_id), '') IS NOT NULL
        GROUP BY user_id, source_type, source_id
        HAVING COUNT(*) > 1
    ) THEN
        RAISE EXCEPTION 'agent action duplicate preflight failed; inspect user_calendar_action_migration_conflicts before creating unique index';
    END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS uq_user_calendar_events_agent_action
    ON user_calendar_events (user_id, source_type, source_id)
    WHERE source_type = 'agent_action' AND source_id <> '';
