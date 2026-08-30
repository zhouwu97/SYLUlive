BEGIN;

ALTER TABLE ai_user_permissions
    DROP CONSTRAINT IF EXISTS chk_ai_user_permissions_scope;

ALTER TABLE ai_user_permissions
    ADD CONSTRAINT chk_ai_user_permissions_scope CHECK (scope IN (
        'ai_personal_data_access',
        'ai_device_cache_access',
        'ai_remote_edu_refresh',
        'erke_snapshot_upload',
        'academic_cloud_storage',
        'ai_external_model_analysis'
    ));

COMMIT;
