-- 旧版数据库：尚未保存响应体和过期时间，也没有唯一约束。
-- 启动迁移必须补齐新列和唯一索引，不能要求人工重建整张表。
CREATE TABLE idempotency_records (
    id bigserial PRIMARY KEY,
    scope varchar(160) NOT NULL,
    idempotency_key varchar(200) NOT NULL,
    method varchar(12) NOT NULL,
    path varchar(512) NOT NULL,
    request_hash varchar(64) NOT NULL,
    state varchar(20) NOT NULL DEFAULT 'processing',
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO idempotency_records
    (scope, idempotency_key, method, path, request_hash, state)
VALUES
    ('credential:legacy', 'legacy-key', 'POST', '/api/legacy', repeat('a', 64), 'processing');

CREATE TABLE migration_fixture_users (
    id bigint PRIMARY KEY,
    nickname text NOT NULL
);
CREATE TABLE migration_fixture_posts (
    id bigint PRIMARY KEY,
    author_id bigint NOT NULL,
    content text NOT NULL
);
CREATE TABLE migration_fixture_post_topics (
    post_id bigint NOT NULL,
    topic_id bigint NOT NULL,
    PRIMARY KEY (post_id, topic_id)
);
INSERT INTO migration_fixture_users (id, nickname) VALUES (1, 'legacy-user'), (2, 'legacy-admin');
INSERT INTO migration_fixture_posts (id, author_id, content) VALUES (10, 1, 'legacy-post');
INSERT INTO migration_fixture_post_topics (post_id, topic_id) VALUES (10, 99);
