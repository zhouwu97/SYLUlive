-- 回填旧水帖分类：空 post_type 统一归入校园生活。
UPDATE posts
SET post_type = 'campus_life'
WHERE board_id = 1
  AND (post_type IS NULL OR post_type = '');

-- 验证结果应为 0。
SELECT COUNT(*) AS empty_water_post_type_count
FROM posts
WHERE board_id = 1
  AND (post_type IS NULL OR post_type = '');
