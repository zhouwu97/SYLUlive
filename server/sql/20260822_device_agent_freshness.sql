-- Device Agent 任务与 tool call 一一对应，避免 Run resume / 网络重试创建两个手机任务。
-- 迁移前应确认历史数据不存在同一 (run_id, tool_call_id) 的重复行。
CREATE UNIQUE INDEX IF NOT EXISTS idx_device_tool_jobs_run_call
    ON device_tool_jobs (run_id, tool_call_id);
