-- 同一等待周期内的设备任务必须幂等；外层工具恢复后若再次发现另一个
-- 缺失数据集，则允许同一 tool call 创建新的任务。终态历史任务不再阻塞新一轮等待。
DROP INDEX IF EXISTS idx_device_tool_jobs_run_call;
CREATE UNIQUE INDEX IF NOT EXISTS idx_device_tool_jobs_run_call_active
    ON device_tool_jobs (run_id, tool_call_id)
    WHERE status IN ('pending', 'pushed', 'claimed', 'waiting_user', 'running');
