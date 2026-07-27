-- 用户主动授权上传的结构化个人快照。
-- 仅允许二课解析结果；密码、Cookie、会话、设备密钥和原始 HTML 均不得写入。
CREATE TABLE IF NOT EXISTS personal_uploaded_snapshots (
    id BIGSERIAL PRIMARY KEY,
    user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    snapshot_type VARCHAR(48) NOT NULL,
    schema_version INTEGER NOT NULL,
    payload_json JSONB NOT NULL,
    payload_hash VARCHAR(64) NOT NULL,
    fetched_at TIMESTAMPTZ NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    is_partial BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_personal_uploaded_snapshots_user_type UNIQUE (user_id, snapshot_type),
    CONSTRAINT chk_personal_uploaded_snapshots_type CHECK (snapshot_type IN ('erke')),
    CONSTRAINT chk_personal_uploaded_snapshots_schema CHECK (schema_version > 0),
    CONSTRAINT chk_personal_uploaded_snapshots_time CHECK (expires_at > fetched_at)
);

CREATE INDEX IF NOT EXISTS idx_personal_uploaded_snapshots_user_expiry
    ON personal_uploaded_snapshots (user_id, expires_at);
