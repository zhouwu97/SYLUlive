-- 图片变体链路验收统计（只读）。
--
-- 用法：
--   docker compose exec -T postgres psql -U postgres -d shenliyuan -f - < scripts/image_pipeline_stats.sql
--
-- 期望：开启 worker 后 ready 持续增长、pending 收敛到 0、failed 稳定在个位数。

\pset pager off

-- 1. 文件权限范围分布
SELECT 'files.access_scope' AS metric, access_scope AS bucket, count(*) AS total
FROM files
GROUP BY access_scope
ORDER BY total DESC;

-- 2. 公开图片中缺少宽高元数据的比例（应接近 0；不为 0 时先跑 backfill_image_metadata）
SELECT 'public_missing_dimensions' AS metric,
       count(*) FILTER (WHERE width = 0 OR height = 0) AS bucket,
       count(*) AS total
FROM files
WHERE access_scope = 'public' AND mime_type LIKE 'image/%';

-- 3. 变体任务状态分布
SELECT 'image_variants.status' AS metric, status AS bucket, count(*) AS total
FROM image_variants
GROUP BY status
ORDER BY total DESC;

-- 4. 仍缺变体的公开图片数（应有引用但还没生成任何档位）
SELECT 'public_without_any_variant' AS metric, 'missing' AS bucket, count(*) AS total
FROM files f
WHERE f.access_scope = 'public'
  AND f.mime_type LIKE 'image/%'
  AND NOT EXISTS (SELECT 1 FROM image_variants v WHERE v.file_id = f.id);

-- 5. 失败原因 Top 10（failed 不为 0 时排查）
SELECT 'failure_reasons' AS metric,
       coalesce(nullif(left(last_error, 120), ''), '(empty)') AS bucket,
       count(*) AS total
FROM image_variants
WHERE status = 'failed'
GROUP BY bucket
ORDER BY total DESC
LIMIT 10;

-- 6. 最近处理完成的 10 个任务（确认 worker 正在推进）
SELECT 'latest_ready' AS metric,
       variant AS bucket,
       updated_at
FROM image_variants
WHERE status = 'ready'
ORDER BY updated_at DESC
LIMIT 10;
