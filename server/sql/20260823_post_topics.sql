-- Topic 核心表。Topic 是全局实体，帖子删除不会删除 Topic。
CREATE TABLE IF NOT EXISTS topics (
    id BIGSERIAL PRIMARY KEY,
    name VARCHAR(80) NOT NULL,
    normalized_name VARCHAR(80) NOT NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'active',
    usage_count INTEGER NOT NULL DEFAULT 0,
    merged_into_id BIGINT REFERENCES topics(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_topics_normalized_name
    ON topics(normalized_name);
CREATE INDEX IF NOT EXISTS idx_topics_status
    ON topics(status);
CREATE INDEX IF NOT EXISTS idx_topics_usage_count
    ON topics(usage_count DESC);

CREATE TABLE IF NOT EXISTS post_topics (
    post_id BIGINT NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
    topic_id BIGINT NOT NULL REFERENCES topics(id),
    sort_order INTEGER NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (post_id, topic_id)
);

CREATE INDEX IF NOT EXISTS idx_post_topics_post_id
    ON post_topics(post_id);
CREATE INDEX IF NOT EXISTS idx_post_topics_topic_id
    ON post_topics(topic_id);
