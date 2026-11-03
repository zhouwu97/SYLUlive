-- 在启用 INTEGRATION_PERSONAL_DATA_ENABLED 前执行；需先有既有个人快照表。
-- 仅扩展允许类型，不改写已有资料。事务失败时保持旧约束；可重复执行。
-- 回滚应用时保留兼容约束，不为恢复旧代码而删除用户上传资料。
BEGIN;
SET LOCAL lock_timeout = '5s';
ALTER TABLE personal_uploaded_snapshots
    DROP CONSTRAINT IF EXISTS chk_personal_uploaded_snapshots_type;
ALTER TABLE personal_uploaded_snapshots
    ADD CONSTRAINT chk_personal_uploaded_snapshots_type
    CHECK (snapshot_type IN ('erke', 'integration_grades'));
COMMIT;
