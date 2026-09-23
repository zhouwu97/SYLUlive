-- 只读盘点：上线前在生产 PostgreSQL 上通过 psql -f 执行，不修改身份状态。
--
-- 与 server/internal/models/academic_identity_inventory.go 覆盖同一批事实；
-- 那边供超级管理员 GET /api/super/academic-identity/verification-inventory 直接读取。
-- 两处都只输出规模与异常形态，不导出学号原文。
--
-- 盘点要回答的问题只有一个：legacy_migration 到底有多少、其中哪些必须人工核对。
-- 在这个问题有数字之前，不能宣称「所有学生身份已经经过可靠学校认证」。

-- 1) 依据分布（含未登记的脏值，按实际存的字符串分组，不做 trim 归并）。
SELECT verification_method, COUNT(*) AS binding_count
FROM academic_identity_bindings
GROUP BY verification_method
ORDER BY binding_count DESC, verification_method;

-- 2) 与服务端判权白名单同一口径的四类计数。
--    trusted 白名单 = school_profile + legacy_migration；local_academic_login 不授予准入。
SELECT
  COUNT(*) FILTER (WHERE verification_method = 'school_profile') AS school_profile_count,
  COUNT(*) FILTER (WHERE verification_method = 'legacy_migration') AS legacy_migration_count,
  COUNT(*) FILTER (WHERE verification_method = 'local_academic_login') AS local_declaration_count,
  COUNT(*) FILTER (WHERE verification_method NOT IN (
    'school_profile', 'legacy_migration', 'local_academic_login'
  )) AS unknown_method_count
FROM academic_identity_bindings;

-- 3) 未登记取值的实际形态。判权用精确匹配，带空白的值不会被当成可信，
--    但它们说明历史写入曾经绕过写入规范，需要人工迁移。
SELECT verification_method, COUNT(*) AS binding_count
FROM academic_identity_bindings
WHERE verification_method NOT IN (
  'school_profile', 'legacy_migration', 'local_academic_login'
)
GROUP BY verification_method
ORDER BY binding_count DESC, verification_method;

SELECT COUNT(*) AS method_whitespace_dirty_count
FROM academic_identity_bindings
WHERE verification_method <> TRIM(verification_method);

-- 4) 缺少验证时间的绑定：准入的最低事实都不完整。零值在 PostgreSQL 里是 0001-01-01。
SELECT verification_method, COUNT(*) AS binding_count
FROM academic_identity_bindings
WHERE verified_at < TIMESTAMP '1970-01-01'
GROUP BY verification_method
ORDER BY binding_count DESC, verification_method;

-- 5) 只返回异常数量，不导出学号或用户 ID。
--    同一教务提供方内的学号关联多个账号，以及同一账号关联多个学号，均需人工核对来源。
--    只看可信绑定：本机声明本来就不授予准入，不在本次处置范围内。
SELECT COUNT(*) AS shared_student_id_count
FROM (
  SELECT provider_id, student_id
  FROM academic_identity_bindings
  WHERE verification_method IN ('school_profile', 'legacy_migration')
  GROUP BY provider_id, student_id
  HAVING COUNT(DISTINCT user_id) > 1
) AS shared_student_ids;

SELECT COUNT(*) AS multi_student_account_count
FROM (
  SELECT user_id
  FROM academic_identity_bindings
  WHERE verification_method IN ('school_profile', 'legacy_migration')
  GROUP BY user_id
  HAVING COUNT(DISTINCT student_id) > 1
) AS multi_student_accounts;

-- 6) 按教务提供方拆开看依据分布：legacy_migration 集中在某个提供方，
--    说明那是历史迁移的来源，重认证的范围也就有了边界。
SELECT provider_id, verification_method, COUNT(*) AS binding_count
FROM academic_identity_bindings
GROUP BY provider_id, verification_method
ORDER BY provider_id, binding_count DESC, verification_method;

-- 7) 重复身份只返回数量，不导出学号。
SELECT COUNT(*) AS duplicate_provider_student_pair_count
FROM (
  SELECT provider_id, student_id
  FROM academic_identity_bindings
  GROUP BY provider_id, student_id
  HAVING COUNT(*) > 1
) AS duplicate_identity_pairs;
