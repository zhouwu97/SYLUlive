BEGIN;

-- 会话删除必须删除 Run 正文链路，但滚动限额账本不能随 Run 级联删除，否则可绕过每小时限制。
ALTER TABLE ai_quota_entries
    DROP CONSTRAINT IF EXISTS ai_quota_entries_run_id_fkey;

COMMIT;
