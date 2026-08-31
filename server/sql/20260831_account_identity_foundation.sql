-- PR3a/PR3b 账号身份基础表。
-- 本迁移只扩展结构，不切换旧登录读路径，也不创建 campus_membership_claims。
BEGIN;

CREATE TABLE IF NOT EXISTS user_login_identities (
    id bigserial PRIMARY KEY,
    user_id bigint NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    type varchar(32) NOT NULL,
    identifier_normalized varchar(320) NOT NULL,
    verified_at timestamptz,
    disabled_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

-- 同一类型、同一规范化标识只允许一个有效 Identity。禁用行仍保留给
-- PR12 审计清理，应用层默认拒绝把它转移给另一 user.id。
CREATE UNIQUE INDEX IF NOT EXISTS ux_user_login_identity_active
    ON user_login_identities(type, identifier_normalized)
    WHERE disabled_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_user_login_identity_user_type
    ON user_login_identities(user_id, type, disabled_at);

CREATE TABLE IF NOT EXISTS registration_sessions (
    id varchar(64) PRIMARY KEY,
    state varchar(24) NOT NULL,
    lock_version bigint NOT NULL DEFAULT 0,
    email_challenge_id varchar(128) NOT NULL DEFAULT '',
    attempt_count integer NOT NULL DEFAULT 0,
    last_attempt_at timestamptz,
    policy_version varchar(32) NOT NULL,
    expires_at timestamptz NOT NULL,
    consumed_at timestamptz,
    idempotency_key_hash varchar(64) NOT NULL DEFAULT '',
    -- 消费记录必须始终带有消费用户；删除用户前应先按 TTL 清理终态 Session。
    -- 使用 RESTRICT 避免 ON DELETE SET NULL 触发 consumed_check 约束冲突。
    consumed_user_id bigint REFERENCES users(id) ON DELETE RESTRICT,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT registration_sessions_state_check CHECK (
        state IN ('pending', 'email_verified', 'admission_ready', 'ready', 'consumed', 'expired', 'locked')
    ),
    CONSTRAINT registration_sessions_attempt_check CHECK (attempt_count >= 0 AND attempt_count <= 5),
    CONSTRAINT registration_sessions_consumed_check CHECK (
        (state = 'consumed' AND consumed_at IS NOT NULL AND consumed_user_id IS NOT NULL)
        OR (state <> 'consumed' AND consumed_at IS NULL AND consumed_user_id IS NULL)
    )
);
CREATE INDEX IF NOT EXISTS ix_registration_sessions_state_expiry
    ON registration_sessions(state, expires_at);
CREATE INDEX IF NOT EXISTS ix_registration_sessions_terminal_cleanup
    ON registration_sessions(state, updated_at);
CREATE INDEX IF NOT EXISTS ix_registration_sessions_consumed_user
    ON registration_sessions(consumed_user_id);

COMMENT ON TABLE user_login_identities IS '规范化登录身份；不保存展示原文';
COMMENT ON TABLE registration_sessions IS '一次性注册状态；不保存学校凭据或校园事实';

COMMIT;
