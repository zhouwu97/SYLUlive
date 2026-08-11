-- MCP 发布阻断安全加固：文件访问范围与举报 pending 唯一约束。
-- 该脚本可重复执行；应用启动期也会执行同等幂等迁移。

ALTER TABLE files
    ADD COLUMN IF NOT EXISTS access_scope VARCHAR(16) NOT NULL DEFAULT 'private';

CREATE INDEX IF NOT EXISTS idx_files_access_scope
    ON files(access_scope);

UPDATE files
SET access_scope = 'private'
WHERE access_scope IS NULL OR access_scope = '';

-- 历史私信附件已被业务引用，激活生命周期但仍保持 private。
UPDATE files
SET status = 'active', claimed_at = COALESCE(claimed_at, CURRENT_TIMESTAMP)
WHERE EXISTS (SELECT 1 FROM messages WHERE messages.file_id = files.id);

-- 只有已经被公开业务引用的文件才回填为 public；其余历史上传保持 private。
UPDATE files
SET access_scope = 'public'
WHERE EXISTS (SELECT 1 FROM post_images WHERE post_images.file_id = files.id)
   OR EXISTS (SELECT 1 FROM reply_images WHERE reply_images.file_id = files.id)
   OR EXISTS (
       SELECT 1 FROM users
       WHERE users.avatar = files.path
          OR users.avatar LIKE files.path || '?%'
          OR users.background = files.path
          OR users.background LIKE files.path || '?%'
   )
   OR EXISTS (
       SELECT 1 FROM water_sections
       WHERE water_sections.avatar_url = files.path
          OR water_sections.cover_url = files.path
          OR water_sections.cover_portrait_url = files.path
          OR water_sections.cover_landscape_url = files.path
          OR water_sections.cover_square_url = files.path
   );

UPDATE files
SET access_scope = 'public'
WHERE EXISTS (
          SELECT 1
          FROM canteens
          WHERE canteens.verified = TRUE
            AND (canteens.image = files.path
              OR canteens.image LIKE files.path || '?%')
      )
   OR EXISTS (
          SELECT 1
          FROM canteen_ratings
          JOIN canteens ON canteens.id = canteen_ratings.canteen_id
          WHERE canteens.verified = TRUE
            AND (canteen_ratings.images LIKE '%' || files.path || '%'
              OR canteen_ratings.images LIKE '%/' || files.path || '%')
      );

DROP INDEX IF EXISTS uq_pending_report_target;

CREATE UNIQUE INDEX IF NOT EXISTS uq_pending_report_target
    ON reports(reporter_id, target_type, target_id)
    WHERE status = 'pending';
