-- 账号身份迁移预检。任何查询返回记录时，都不得执行正式迁移。

SELECT 'duplicate_edu_student_id' AS issue, edu_student_id AS value, array_agg(id ORDER BY id) AS user_ids
FROM users
WHERE edu_student_id <> ''
GROUP BY edu_student_id
HAVING count(*) > 1;

SELECT 'student_and_edu_mismatch' AS issue, id, student_id, edu_student_id
FROM users
WHERE student_id ~ '^[0-9]{10}$'
  AND edu_student_id <> ''
  AND student_id <> edu_student_id;

SELECT 'duplicate_qq' AS issue, qq AS value, array_agg(id ORDER BY id) AS user_ids
FROM users
WHERE qq <> ''
GROUP BY qq
HAVING count(*) > 1;

SELECT 'qq_email_would_collide_with_student' AS issue, u.id, u.qq, peer.id AS peer_id, peer.student_id
FROM users AS u
JOIN users AS peer ON lower(u.qq || '@qq.com') = lower(peer.student_id)
WHERE u.qq <> ''
  AND u.student_id = u.qq
  AND peer.id <> u.id;

SELECT 'student_identity_already_owned_by_qq_account' AS issue, edu_student_id AS student_id, array_agg(id ORDER BY id) AS user_ids
FROM users
WHERE edu_student_id <> ''
GROUP BY edu_student_id
HAVING count(*) > 1;

SELECT 'unverified_ten_digit_student_id' AS issue, id, student_id, edu_student_id, edu_bound, created_at
FROM users
WHERE student_id ~ '^[0-9]{10}$'
  AND COALESCE(edu_student_id, '') <> student_id
  AND COALESCE(edu_bound, false) = false;
