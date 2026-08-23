-- 设备桥接只允许写入受控 progress stage；用户可见标题由 Agent activity reducer 生成。
ALTER TABLE device_tool_jobs
    ADD COLUMN IF NOT EXISTS progress_stage VARCHAR(32) NOT NULL DEFAULT '';
