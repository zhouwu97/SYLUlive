-- 举报治理闭环：保留作者整改/申诉所需的帖子状态、版本与复审记录。
ALTER TABLE posts ADD COLUMN IF NOT EXISTS revision INTEGER NOT NULL DEFAULT 1;
ALTER TABLE posts ADD COLUMN IF NOT EXISTS moderation_rule_code VARCHAR(80);
ALTER TABLE posts ADD COLUMN IF NOT EXISTS moderation_reason VARCHAR(1000);
ALTER TABLE posts ADD COLUMN IF NOT EXISTS moderated_by_id BIGINT;
ALTER TABLE posts ADD COLUMN IF NOT EXISTS moderated_at TIMESTAMPTZ;
ALTER TABLE reports ADD COLUMN IF NOT EXISTS moderated_revision INTEGER;

CREATE INDEX IF NOT EXISTS idx_posts_moderated_by_id ON posts(moderated_by_id);
CREATE INDEX IF NOT EXISTS idx_posts_moderated_at ON posts(moderated_at);
CREATE INDEX IF NOT EXISTS idx_reports_moderated_revision ON reports(moderated_revision);

CREATE TABLE IF NOT EXISTS post_rectification_reviews (
  id BIGSERIAL PRIMARY KEY,
  post_id BIGINT NOT NULL,
  report_id BIGINT,
  submitted_revision INTEGER NOT NULL,
  status VARCHAR(20) NOT NULL DEFAULT 'pending',
  reviewer_id BIGINT,
  review_reason VARCHAR(1000),
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  reviewed_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_post_rectification_reviews_post_id ON post_rectification_reviews(post_id);
CREATE INDEX IF NOT EXISTS idx_post_rectification_reviews_status ON post_rectification_reviews(status);
CREATE INDEX IF NOT EXISTS idx_post_rectification_reviews_reviewer_id ON post_rectification_reviews(reviewer_id);
CREATE UNIQUE INDEX IF NOT EXISTS uq_post_rectification_pending
  ON post_rectification_reviews(post_id) WHERE status = 'pending';
