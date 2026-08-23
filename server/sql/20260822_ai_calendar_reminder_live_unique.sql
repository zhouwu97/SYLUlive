BEGIN;

-- 软删除提醒不应阻止同一事件再次添加相同提前量。
ALTER TABLE user_calendar_reminders
    DROP CONSTRAINT IF EXISTS uq_user_calendar_reminders_event_offset;
DROP INDEX IF EXISTS idx_user_calendar_reminders_event_offset;
CREATE UNIQUE INDEX IF NOT EXISTS uq_user_calendar_reminders_event_offset_live
    ON user_calendar_reminders (event_id, minutes_before)
    WHERE deleted_at IS NULL;

COMMIT;
