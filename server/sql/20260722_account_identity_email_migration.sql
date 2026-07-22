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

ALTER TABLE users ALTER COLUMN student_id DROP NOT NULL;
ALTER TABLE users ALTER COLUMN student_id SET DEFAULT '';

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

DROP INDEX IF EXISTS idx_users_student_id;
CREATE UNIQUE INDEX IF NOT EXISTS ux_users_student_id_nonempty ON users(student_id) WHERE student_id <> '';
CREATE UNIQUE INDEX IF NOT EXISTS ux_users_email_nonempty ON users(email) WHERE email <> '';
CREATE UNIQUE INDEX IF NOT EXISTS ux_users_edu_student_id_nonempty ON users(edu_student_id) WHERE edu_student_id <> '';
CREATE INDEX IF NOT EXISTS ix_email_verification_active ON email_verification_challenges(email, purpose, created_at DESC) WHERE consumed_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_email_verification_ip_created ON email_verification_challenges(request_ip_hash, created_at DESC);
CREATE INDEX IF NOT EXISTS ix_account_security_audit_user_created ON account_security_audit_logs(user_id, created_at DESC);

COMMIT;
