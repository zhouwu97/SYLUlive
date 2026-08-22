-- 通用个人日历与 AI 行动草稿。正式写入仍需用户确认，模型不能直接写入事件表。
CREATE TABLE IF NOT EXISTS user_calendars (
    id BIGSERIAL PRIMARY KEY,
    user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name VARCHAR(100) NOT NULL,
    timezone VARCHAR(64) NOT NULL DEFAULT 'Asia/Shanghai',
    is_default BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_user_calendars_user_name UNIQUE (user_id, name)
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_user_calendars_user_default
    ON user_calendars(user_id) WHERE is_default = TRUE;

CREATE TABLE IF NOT EXISTS user_calendar_events (
    id BIGSERIAL PRIMARY KEY,
    user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    calendar_id BIGINT NOT NULL REFERENCES user_calendars(id) ON DELETE CASCADE,
    title VARCHAR(160) NOT NULL,
    description TEXT NOT NULL DEFAULT '',
    start_at TIMESTAMPTZ NOT NULL,
    end_at TIMESTAMPTZ NOT NULL,
    all_day BOOLEAN NOT NULL DEFAULT FALSE,
    location VARCHAR(200) NOT NULL DEFAULT '',
    timezone VARCHAR(64) NOT NULL DEFAULT 'Asia/Shanghai',
    source_type VARCHAR(32) NOT NULL DEFAULT 'manual',
    source_id VARCHAR(128) NOT NULL DEFAULT '',
    source_version BIGINT NOT NULL DEFAULT 1,
    sync_mode VARCHAR(24) NOT NULL DEFAULT 'snapshot',
    version BIGINT NOT NULL DEFAULT 1,
    created_by VARCHAR(24) NOT NULL DEFAULT 'user',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_user_calendar_events_user_time
    ON user_calendar_events(user_id, start_at);

CREATE TABLE IF NOT EXISTS user_calendar_reminders (
    id BIGSERIAL PRIMARY KEY,
    user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    event_id BIGINT NOT NULL REFERENCES user_calendar_events(id) ON DELETE CASCADE,
    minutes_before INTEGER NOT NULL CHECK (minutes_before >= 0 AND minutes_before <= 10080),
    version BIGINT NOT NULL DEFAULT 1,
    created_by VARCHAR(24) NOT NULL DEFAULT 'user',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at TIMESTAMPTZ,
    CONSTRAINT uq_user_calendar_reminders_event_offset UNIQUE (event_id, minutes_before)
);

CREATE TABLE IF NOT EXISTS user_calendar_action_drafts (
    id BIGSERIAL PRIMARY KEY,
    user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    action_type VARCHAR(64) NOT NULL,
    status VARCHAR(24) NOT NULL,
    title VARCHAR(160) NOT NULL,
    description TEXT NOT NULL DEFAULT '',
    start_at TIMESTAMPTZ NOT NULL,
    end_at TIMESTAMPTZ NOT NULL,
    all_day BOOLEAN NOT NULL DEFAULT FALSE,
    location VARCHAR(200) NOT NULL DEFAULT '',
    timezone VARCHAR(64) NOT NULL DEFAULT 'Asia/Shanghai',
    payload_hash VARCHAR(64) NOT NULL,
    idempotency_key VARCHAR(100) NOT NULL,
    target_event_id BIGINT REFERENCES user_calendar_events(id) ON DELETE SET NULL,
    target_event_version BIGINT NOT NULL DEFAULT 0,
    reminder_minutes_before INTEGER CHECK (reminder_minutes_before IS NULL OR (reminder_minutes_before >= 0 AND reminder_minutes_before <= 10080)),
    calendar_event_id BIGINT REFERENCES user_calendar_events(id) ON DELETE SET NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    confirmed_at TIMESTAMPTZ,
    executed_at TIMESTAMPTZ,
    cancelled_at TIMESTAMPTZ,
    failure_reason VARCHAR(200) NOT NULL DEFAULT '',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_user_calendar_action_drafts_user_key UNIQUE (user_id, idempotency_key)
);

CREATE TABLE IF NOT EXISTS user_calendar_action_audits (
    id BIGSERIAL PRIMARY KEY,
    draft_id BIGINT NOT NULL REFERENCES user_calendar_action_drafts(id) ON DELETE CASCADE,
    user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    action VARCHAR(32) NOT NULL,
    client_request_id VARCHAR(100) NOT NULL DEFAULT '',
    result VARCHAR(100) NOT NULL DEFAULT '',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 兼容早期已创建过行动草稿表的环境；CREATE TABLE IF NOT EXISTS 不会补齐新字段。
ALTER TABLE user_calendar_action_drafts
    ADD COLUMN IF NOT EXISTS target_event_id BIGINT REFERENCES user_calendar_events(id) ON DELETE SET NULL;
ALTER TABLE user_calendar_action_drafts
    ADD COLUMN IF NOT EXISTS target_event_version BIGINT NOT NULL DEFAULT 0;
ALTER TABLE user_calendar_action_drafts
    ADD COLUMN IF NOT EXISTS reminder_minutes_before INTEGER CHECK (reminder_minutes_before IS NULL OR (reminder_minutes_before >= 0 AND reminder_minutes_before <= 10080));
