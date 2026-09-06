-- 账号身份、邮箱与教务会话迁移。执行前必须先运行 precheck SQL 并确认零冲突。
BEGIN;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM users WHERE edu_student_id <> '' GROUP BY edu_student_id HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION 'edu_student_id contains duplicate bindings';
  END IF;
END $$;

ALTER TABLE users ADD COLUMN IF NOT EXISTS student_verified_at timestamptz;
ALTER TABLE users ADD COLUMN IF NOT EXISTS email varchar(320) NOT NULL DEFAULT '';
ALTER TABLE users ADD COLUMN IF NOT EXISTS email_verified_at timestamptz;
ALTER TABLE users ADD COLUMN IF NOT EXISTS edu_authorized boolean NOT NULL DEFAULT false;
ALTER TABLE users ADD COLUMN IF NOT EXISTS edu_session_state varchar(20) NOT NULL DEFAULT 'unbound';
ALTER TABLE users ADD COLUMN IF NOT EXISTS edu_auto_relogin boolean NOT NULL DEFAULT true;
ALTER TABLE users ADD COLUMN IF NOT EXISTS edu_authorized_at timestamptz;
ALTER TABLE users ADD COLUMN IF NOT EXISTS edu_session_updated_at timestamptz;
ALTER TABLE users ADD COLUMN IF NOT EXISTS edu_authorization_generation bigint NOT NULL DEFAULT 0;
ALTER TABLE users ADD COLUMN IF NOT EXISTS edu_cleanup_pending boolean NOT NULL DEFAULT false;
ALTER TABLE users ADD COLUMN IF NOT EXISTS edu_binding_state varchar(32) NOT NULL DEFAULT 'idle';
ALTER TABLE users ADD COLUMN IF NOT EXISTS edu_binding_pending_generation bigint NOT NULL DEFAULT 0;
ALTER TABLE users ADD COLUMN IF NOT EXISTS edu_binding_pending_student_id varchar(20) NOT NULL DEFAULT '';
ALTER TABLE users ADD COLUMN IF NOT EXISTS edu_binding_started_at timestamptz;
ALTER TABLE users ADD COLUMN IF NOT EXISTS account_status varchar(20) NOT NULL DEFAULT 'active';
ALTER TABLE users ADD COLUMN IF NOT EXISTS cancelled_at timestamptz;

ALTER TABLE users ALTER COLUMN student_id DROP NOT NULL;
ALTER TABLE users ALTER COLUMN student_id SET DEFAULT '';

-- 旧全量唯一索引必须先删除。否则多个未绑定教务的 QQ 账号在迁移为
-- 空 student_id 时会立即触发唯一约束，导致事务在创建部分索引前回滚。
DROP INDEX IF EXISTS idx_users_student_id;

-- 历史 QQ 注册已经完成 QQ 邮箱验证码校验，可转换为已验证邮箱。
UPDATE users
SET email = lower(qq || '@qq.com'),
    email_verified_at = COALESCE(email_verified_at, created_at),
    student_id = CASE WHEN edu_student_id <> '' THEN edu_student_id ELSE '' END,
    student_verified_at = CASE
      WHEN edu_student_id <> '' THEN COALESCE(student_verified_at, now())
      ELSE student_verified_at
    END
WHERE qq <> '' AND student_id = qq;

UPDATE users
SET student_verified_at = COALESCE(student_verified_at, created_at, now())
WHERE student_id ~ '^[0-9]{10}$'
  AND (edu_student_id = student_id OR edu_bound = true);

UPDATE users
SET edu_authorized = COALESCE(edu_bound, false),
    edu_session_state = CASE
      WHEN COALESCE(edu_bound, false) THEN 'active'
      ELSE 'unbound'
    END,
    edu_auto_relogin = COALESCE(edu_bound, false),
    edu_authorized_at = CASE WHEN COALESCE(edu_bound, false) THEN COALESCE(edu_authorized_at, created_at, now()) ELSE NULL END,
    edu_session_updated_at = COALESCE(edu_session_updated_at, now()),
    edu_authorization_generation = CASE WHEN COALESCE(edu_bound, false) THEN GREATEST(edu_authorization_generation, 1) ELSE edu_authorization_generation END,
    edu_binding_state = CASE WHEN COALESCE(edu_bound, false) THEN 'active' ELSE COALESCE(edu_binding_state, 'idle') END,
    edu_binding_pending_generation = CASE WHEN COALESCE(edu_bound, false) THEN 0 ELSE COALESCE(edu_binding_pending_generation, 0) END,
    edu_binding_started_at = NULL,
    edu_bound = COALESCE(edu_bound, false);

-- Go 侧遗留凭据不再使用，迁移时立即清除。
UPDATE users SET edu_password = '', edu_cookie = '';

CREATE TABLE IF NOT EXISTS email_verification_challenges (
  id bigserial PRIMARY KEY,
  user_id bigint REFERENCES users(id) ON DELETE CASCADE,
  email varchar(320) NOT NULL,
  purpose varchar(32) NOT NULL,
  code_hash varchar(255) NOT NULL,
  attempts integer NOT NULL DEFAULT 0,
  expires_at timestamptz NOT NULL,
  consumed_at timestamptz,
  request_ip_hash varchar(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS account_security_audit_logs (
  id bigserial PRIMARY KEY,
  user_id bigint NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  action varchar(64) NOT NULL,
  metadata text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS email_verification_requests (
  id bigserial PRIMARY KEY,
  email varchar(320) NOT NULL,
  purpose varchar(32) NOT NULL,
  request_ip_hash varchar(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS edu_credential_cleanup_jobs (
  id bigserial PRIMARY KEY,
  user_id bigint NOT NULL REFERENCES users(id),
  expected_generation bigint NOT NULL DEFAULT 0,
  revoked_at timestamptz,
  delete_identity boolean NOT NULL DEFAULT false,
  attempts integer NOT NULL DEFAULT 0,
  next_attempt_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz,
  locked_at timestamptz,
  lock_token varchar(36) NOT NULL DEFAULT '',
  last_error varchar(1000) NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE edu_credential_cleanup_jobs ADD COLUMN IF NOT EXISTS expected_generation bigint NOT NULL DEFAULT 0;
ALTER TABLE edu_credential_cleanup_jobs ADD COLUMN IF NOT EXISTS revoked_at timestamptz;
ALTER TABLE edu_credential_cleanup_jobs ADD COLUMN IF NOT EXISTS delete_identity boolean NOT NULL DEFAULT false;
ALTER TABLE edu_credential_cleanup_jobs ADD COLUMN IF NOT EXISTS attempts integer NOT NULL DEFAULT 0;
ALTER TABLE edu_credential_cleanup_jobs ADD COLUMN IF NOT EXISTS next_attempt_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE edu_credential_cleanup_jobs ADD COLUMN IF NOT EXISTS completed_at timestamptz;
ALTER TABLE edu_credential_cleanup_jobs ADD COLUMN IF NOT EXISTS locked_at timestamptz;
ALTER TABLE edu_credential_cleanup_jobs ADD COLUMN IF NOT EXISTS lock_token varchar(36) NOT NULL DEFAULT '';
ALTER TABLE edu_credential_cleanup_jobs ADD COLUMN IF NOT EXISTS last_error varchar(1000) NOT NULL DEFAULT '';
ALTER TABLE edu_credential_cleanup_jobs ADD COLUMN IF NOT EXISTS created_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE edu_credential_cleanup_jobs ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();

-- 合并历史上同一用户、同一授权代次的重复任务。永久删除身份是更强语义，
-- 必须保留在唯一的待处理任务中，普通撤销任务不能将其提前完成。
WITH pending AS (
  SELECT user_id, expected_generation, MIN(id) AS keep_id, BOOL_OR(delete_identity) AS delete_identity
  FROM edu_credential_cleanup_jobs
  WHERE completed_at IS NULL
  GROUP BY user_id, expected_generation
)
UPDATE edu_credential_cleanup_jobs AS job
SET delete_identity = pending.delete_identity
FROM pending
WHERE job.id = pending.keep_id;

WITH pending AS (
  SELECT user_id, expected_generation, MIN(id) AS keep_id
  FROM edu_credential_cleanup_jobs
  WHERE completed_at IS NULL
  GROUP BY user_id, expected_generation
)
UPDATE edu_credential_cleanup_jobs AS job
SET completed_at = now(),
    last_error = '已合并到同一授权代次的清理任务',
    locked_at = NULL,
    lock_token = ''
FROM pending
WHERE job.user_id = pending.user_id
  AND job.expected_generation = pending.expected_generation
  AND job.id <> pending.keep_id
  AND job.completed_at IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS ux_edu_cleanup_pending_generation
ON edu_credential_cleanup_jobs(user_id, expected_generation)
WHERE completed_at IS NULL;

-- 原索引无法同时保留注册和后续教务绑定的独立专项授权证据。
DROP INDEX IF EXISTS idx_user_legal_document_version;
CREATE UNIQUE INDEX IF NOT EXISTS idx_user_legal_document_version_scene
ON user_legal_consents(user_id, document, version, scene);

CREATE UNIQUE INDEX IF NOT EXISTS ux_users_student_id_nonempty ON users(student_id) WHERE student_id <> '';
CREATE UNIQUE INDEX IF NOT EXISTS ux_users_email_nonempty ON users(email) WHERE email <> '';
CREATE UNIQUE INDEX IF NOT EXISTS ux_users_edu_student_id_nonempty ON users(edu_student_id) WHERE edu_student_id <> '';
CREATE INDEX IF NOT EXISTS ix_email_verification_active ON email_verification_challenges(email, purpose, created_at DESC) WHERE consumed_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_email_verification_ip_created ON email_verification_challenges(request_ip_hash, created_at DESC);
CREATE INDEX IF NOT EXISTS ix_email_verification_request_email_created ON email_verification_requests(email, purpose, created_at DESC);
CREATE INDEX IF NOT EXISTS ix_email_verification_request_ip_created ON email_verification_requests(request_ip_hash, created_at DESC);
CREATE INDEX IF NOT EXISTS ix_account_security_audit_user_created ON account_security_audit_logs(user_id, created_at DESC);

-- 活跃账号必须始终保留至少一个已验证登录身份。迁移前若存在冲突应停止发布，
-- 由运维先完成身份补录，不能通过自动删除或伪造字段掩盖问题。
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM users
    WHERE account_status = 'active'
      AND NOT (
        (student_verified_at IS NOT NULL AND COALESCE(student_id, '') <> '')
        OR (email_verified_at IS NOT NULL AND COALESCE(email, '') <> '')
      )
  ) THEN
    RAISE EXCEPTION 'active users must retain at least one verified login identity';
  END IF;
END $$;

ALTER TABLE users DROP CONSTRAINT IF EXISTS ck_users_active_login_identity;
ALTER TABLE users ADD CONSTRAINT ck_users_active_login_identity CHECK (
  account_status <> 'active'
  OR (student_verified_at IS NOT NULL AND COALESCE(student_id, '') <> '')
  OR (email_verified_at IS NOT NULL AND COALESCE(email, '') <> '')
);

COMMIT;
