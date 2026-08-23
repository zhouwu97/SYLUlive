-- Agent 日历动作以草稿 ID 作为最终写入幂等键，防止并发确认重复创建事件。
CREATE UNIQUE INDEX IF NOT EXISTS uq_user_calendar_events_agent_action
    ON user_calendar_events (user_id, source_type, source_id)
    WHERE source_type = 'agent_action' AND source_id <> '';
