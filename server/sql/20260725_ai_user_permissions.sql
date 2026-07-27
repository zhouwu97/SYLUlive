-- 校园 Agent 的长期个人数据授权偏好。缺少记录时由应用按 ask 处理。
CREATE TABLE IF NOT EXISTS ai_user_permissions (
    id BIGSERIAL PRIMARY KEY,
    user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    scope VARCHAR(48) NOT NULL,
    policy VARCHAR(16) NOT NULL DEFAULT 'ask',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_ai_user_permissions_user_scope UNIQUE (user_id, scope),
    CONSTRAINT chk_ai_user_permissions_scope CHECK (scope IN (
        'ai_personal_data_access',
        'ai_device_cache_access',
        'ai_remote_edu_refresh',
        'erke_snapshot_upload',
        'academic_cloud_storage'
    )),
    CONSTRAINT chk_ai_user_permissions_policy CHECK (policy IN ('ask', 'always', 'never'))
);

CREATE INDEX IF NOT EXISTS idx_ai_user_permissions_user_updated
    ON ai_user_permissions (user_id, updated_at DESC);
