-- 生产环境须在部署新代码前执行。本迁移不删除任何 edu_users 记录。
-- PostgreSQL：将旧 bound 语义拆分为授权和会话状态，并为学号建立最终唯一约束。

BEGIN;

ALTER TABLE edu_users ADD COLUMN IF NOT EXISTS authorized boolean NOT NULL DEFAULT false;
ALTER TABLE edu_users ADD COLUMN IF NOT EXISTS session_state varchar(20) NOT NULL DEFAULT 'unbound';
ALTER TABLE edu_users ADD COLUMN IF NOT EXISTS auto_relogin boolean NOT NULL DEFAULT true;
ALTER TABLE edu_users ADD COLUMN IF NOT EXISTS authorized_at timestamp NULL;
ALTER TABLE edu_users ADD COLUMN IF NOT EXISTS logged_out_at timestamp NULL;
ALTER TABLE edu_users ADD COLUMN IF NOT EXISTS revoked_at timestamp NULL;

-- 仅将旧已绑定账号升级为已授权的活跃会话；旧数据没有“主动退出”证据。
UPDATE edu_users
SET authorized = true,
    session_state = CASE WHEN cookie IS NULL OR cookie = '' THEN 'expired' ELSE 'active' END,
    auto_relogin = true,
    authorized_at = COALESCE(authorized_at, updated_at, created_at)
WHERE bound = true;

UPDATE edu_users
SET authorized = false,
    session_state = 'unbound',
    auto_relogin = false
WHERE bound = false AND session_state = 'unbound';

DO $$
BEGIN
    IF EXISTS (
        SELECT student_id
        FROM edu_users
        GROUP BY student_id
        HAVING COUNT(*) > 1
    ) THEN
        RAISE EXCEPTION 'edu_users.student_id has duplicate values; resolve conflicts before adding the unique index';
    END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS ux_edu_users_student_id ON edu_users(student_id);

COMMIT;
