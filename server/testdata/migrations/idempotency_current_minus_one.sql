-- 当前版本前一版数据库：已有响应字段，但还缺少过期时间。
CREATE TABLE idempotency_records (
    id bigserial PRIMARY KEY,
    scope varchar(160) NOT NULL,
    idempotency_key varchar(200) NOT NULL,
    method varchar(12) NOT NULL,
    path varchar(512) NOT NULL,
    request_hash varchar(64) NOT NULL,
    state varchar(20) NOT NULL DEFAULT 'processing',
    response_code integer NOT NULL DEFAULT 200,
    content_type varchar(160) NOT NULL DEFAULT '',
    response_body bytea,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX idx_idempotency_scope_key_route
    ON idempotency_records (scope, idempotency_key, method, path);
INSERT INTO idempotency_records
    (scope, idempotency_key, method, path, request_hash, state)
VALUES
    ('credential:previous', 'previous-key', 'POST', '/api/previous', repeat('b', 64), 'processing');

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
INSERT INTO migration_fixture_users (id, nickname) VALUES (1, 'previous-user'), (2, 'previous-admin');
INSERT INTO migration_fixture_posts (id, author_id, content) VALUES (10, 1, 'previous-post');
INSERT INTO migration_fixture_post_topics (post_id, topic_id) VALUES (10, 99);
