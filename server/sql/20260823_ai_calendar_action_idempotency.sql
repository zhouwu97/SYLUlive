-- Agent 日历动作以草稿 ID 作为最终写入幂等键，防止并发确认重复创建事件。
-- 迁移不删除历史记录；先登记冲突并阻断，由运维按 Draft/审计规则显式去重。
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
