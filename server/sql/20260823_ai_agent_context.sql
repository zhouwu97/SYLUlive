-- AI Run 保存经过服务端校验的最小页面上下文引用，用于异步执行和恢复。
ALTER TABLE ai_runs
    ADD COLUMN IF NOT EXISTS agent_context JSONB NOT NULL DEFAULT '{}'::jsonb;

