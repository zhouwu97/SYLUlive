-- Agent Runtime 生产健壮性：保存可恢复状态，并为工具结果建立规划版本栅栏。
ALTER TABLE ai_runs
    ADD COLUMN IF NOT EXISTS agent_state_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    ADD COLUMN IF NOT EXISTS planning_round INTEGER NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS constraint_version INTEGER NOT NULL DEFAULT 1,
    ADD COLUMN IF NOT EXISTS plan_version INTEGER NOT NULL DEFAULT 1;

ALTER TABLE ai_tool_calls
    ADD COLUMN IF NOT EXISTS planning_round INTEGER NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS constraint_version INTEGER NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS plan_version INTEGER NOT NULL DEFAULT 0;

CREATE INDEX IF NOT EXISTS idx_ai_tool_calls_run_plan
    ON ai_tool_calls(run_id, planning_round, constraint_version);
