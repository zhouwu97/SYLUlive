-- 规范化历史法律同意记录的场景字段。
-- 仅 NULL 表示旧版本未区分场景，按历史默认语义归入 registration；
-- 已有非空场景保持不变，避免把未来或未知场景静默改写。
BEGIN;

UPDATE user_legal_consents
SET scene = 'registration'
WHERE scene IS NULL;

ALTER TABLE user_legal_consents
  ALTER COLUMN scene SET DEFAULT 'registration';

ALTER TABLE user_legal_consents
  ALTER COLUMN scene SET NOT NULL;

COMMIT;
