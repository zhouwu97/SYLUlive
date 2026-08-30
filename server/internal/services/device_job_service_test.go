package services

import (
	"context"
	"encoding/json"
	"errors"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	"gorm.io/datatypes"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

func newDeviceJobFixture(t *testing.T, now time.Time) (*gorm.DB, *DeviceJobService) {
	t.Helper()
	db, err := gorm.Open(sqlite.Open("file:"+t.Name()+"?mode=memory&cache=shared"), &gorm.Config{})
	if err != nil {
		t.Fatal(err)
	}
	if err := db.AutoMigrate(&models.User{}, &models.UserDevice{}, &models.DeviceToolJob{}, &models.AIRun{}); err != nil {
		t.Fatal(err)
	}
	if err := models.EnsureDeviceToolJobIndexes(db); err != nil {
		t.Fatal(err)
	}
	if err := db.Create(&models.User{PasswordHash: "test"}).Error; err != nil {
		t.Fatal(err)
	}
	service := NewDeviceJobService(db)
	service.clock = func() time.Time { return now }
	return db, service
}

func registerTestDevice(t *testing.T, service *DeviceJobService, userID uint, installationID string) *models.UserDevice {
	t.Helper()
	device, err := service.RegisterDevice(context.Background(), userID, DeviceRegistration{
		InstallationID:        installationID,
		ToolNames:             []string{"device.academic.get_cached_overview", "device.academic.ensure_fresh_grade_summary", "device.academic.ensure_fresh_risk_context", "device.academic.ensure_fresh_bundle", "device.schedule.get_cached_week", "device.academic.get_credit_summary", "device.erke.get_cached_overview"},
		BridgeProtocolVersion: 2,
	})
	if err != nil {
		t.Fatal(err)
	}
	return device
}

func createTestDeviceJob(t *testing.T, service *DeviceJobService, userID uint, now time.Time) *models.DeviceToolJob {
	t.Helper()
	job, err := service.CreateJob(context.Background(), CreateDeviceJobRequest{
		UserID: userID, RunID: "run-1", ToolCallID: "call-1", ToolName: "device.academic.get_cached_overview",
		Arguments: json.RawMessage(`{}`), RequiredDataTypes: []string{"academic"}, ExpiresAt: now.Add(time.Minute),
	})
	if err != nil {
		t.Fatal(err)
	}
	return job
}

func TestDeviceJobRejectsCrossUserDeviceAccess(t *testing.T) {
	now := time.Date(2026, 7, 25, 9, 0, 0, 0, time.UTC)
	db, service := newDeviceJobFixture(t, now)
	registerTestDevice(t, service, 1, "installation-user-1")
	job := createTestDeviceJob(t, service, 1, now)
	if err := db.Create(&models.User{PasswordHash: "test-2"}).Error; err != nil {
		t.Fatal(err)
	}
	registerTestDevice(t, service, 2, "installation-user-2")
	_, err := service.GetJob(context.Background(), 2, "installation-user-2", job.ID)
	assertDeviceJobCode(t, err, "device_job_not_found")
}

func TestDeviceJobProgressAcceptsOnlyOrderedStages(t *testing.T) {
	_, service := newDeviceJobFixture(t, time.Now().UTC().Add(time.Minute))
	registerTestDevice(t, service, 1, "progress-installation")
	job, err := service.CreateJob(context.Background(), CreateDeviceJobRequest{
		UserID: 1, RunID: "run-progress", ToolCallID: "call-progress",
		ToolName:  "device.academic.ensure_fresh_grade_summary",
		Arguments: json.RawMessage(`{"max_age_seconds":300}`), RequiredDataTypes: []string{"grades"},
	})
	require.NoError(t, err)
	claimed, err := service.ClaimJob(context.Background(), 1, "progress-installation", job.ID, job.StateVersion)
	require.NoError(t, err)
	progress, err := service.ProgressJob(context.Background(), 1, "progress-installation", job.ID, claimed.StateVersion, models.DeviceJobStageCheckingFreshness)
	require.NoError(t, err)
	progress, err = service.ProgressJob(context.Background(), 1, "progress-installation", job.ID, progress.StateVersion, models.DeviceJobStageRequestReceived)
	require.NoError(t, err)
	progress, err = service.ProgressJob(context.Background(), 1, "progress-installation", job.ID, progress.StateVersion, models.DeviceJobStageRefreshStarted)
	require.NoError(t, err)
	_, err = service.ProgressJob(context.Background(), 1, "progress-installation", job.ID, progress.StateVersion, "made_up_stage")
	var deviceErr *DeviceJobError
	require.ErrorAs(t, err, &deviceErr)
	require.Equal(t, "invalid_progress_stage", deviceErr.Code)
}

func TestDeviceJobBundleAcceptsFreshAcademicDatasets(t *testing.T) {
	now := time.Date(2026, 7, 25, 9, 0, 0, 0, time.UTC)
	_, service := newDeviceJobFixture(t, now)
	registerTestDevice(t, service, 1, "bundle-installation")
	job, err := service.CreateJob(context.Background(), CreateDeviceJobRequest{
		UserID: 1, RunID: "run-bundle", ToolCallID: "call-bundle",
		ToolName:          "device.academic.ensure_fresh_bundle",
		Arguments:         json.RawMessage(`{"max_age_seconds":{"grades":300,"academic_situation":21600,"credit_requirements":86400}}`),
		RequiredDataTypes: []string{"grades", "academic_situation", "credit_requirements"},
		ExpiresAt:         now.Add(time.Minute),
	})
	require.NoError(t, err)
	claimed, err := service.ClaimJob(context.Background(), 1, "bundle-installation", job.ID, 0)
	require.NoError(t, err)
	completed, err := service.CompleteJob(context.Background(), 1, "bundle-installation", job.ID, claimed.StateVersion, bundleDeviceToolTestResult())
	require.NoError(t, err)
	require.Equal(t, models.DeviceToolJobCompleted, completed.Status)
}

func TestDeviceJobErkeOverviewAcceptsNativeDateFormats(t *testing.T) {
	now := time.Date(2026, 7, 25, 9, 0, 0, 0, time.UTC)
	_, service := newDeviceJobFixture(t, now)
	if _, err := service.RegisterDevice(context.Background(), 1, DeviceRegistration{
		InstallationID:        "erke-refresh-installation",
		ToolNames:             []string{"device.erke.ensure_fresh_overview"},
		BridgeProtocolVersion: 2,
	}); err != nil {
		t.Fatal(err)
	}
	job, err := service.CreateJob(context.Background(), CreateDeviceJobRequest{
		UserID: 1, RunID: "run-erke", ToolCallID: "call-erke",
		ToolName:          "device.erke.ensure_fresh_overview",
		Arguments:         json.RawMessage(`{"max_age_seconds":1800,"allow_upload":true}`),
		RequiredDataTypes: []string{"erke"},
		ExpiresAt:         now.Add(time.Minute),
	})
	require.NoError(t, err)
	claimed, err := service.ClaimJob(context.Background(), 1, "erke-refresh-installation", job.ID, 0)
	require.NoError(t, err)

	// 二课系统返回的日期是 "2026.05.26-05.27" / "2026.05.26 13:00" 原文，不是 ISO 日期。
	refreshed := json.RawMessage(`{
		"data":{"earned_total":40.75,"required_total":40,"unmet_categories":[{"name":"实践实习","gap":10.0}],"activity_count":50,"latest_activity_date":"2026.05.26-05.27"},
		"source":"remote_edu_fetch",
		"fetched_at":"2026-07-25T09:00:00Z",
		"expires_at":"2026-07-25T09:30:00Z",
		"is_stale":false,
		"is_partial":false,
		"warnings":["二课已更新，但摘要上传失败"],
		"evidence":[{"source":"remote_edu_fetch","fetched_at":"2026-07-25T09:00:00Z","expires_at":"2026-07-25T09:30:00Z","is_stale":false}],
		"freshness":{"before":"stale","after":"fresh"},
		"refresh_performed":true
	}`)
	completed, err := service.CompleteJob(context.Background(), 1, "erke-refresh-installation", job.ID, claimed.StateVersion, refreshed)
	require.NoError(t, err)
	require.Equal(t, models.DeviceToolJobCompleted, completed.Status)
}

func TestDeviceJobErkeOverviewRejectsOverlongActivityDate(t *testing.T) {
	now := time.Date(2026, 7, 25, 9, 0, 0, 0, time.UTC)
	_, service := newDeviceJobFixture(t, now)
	if _, err := service.RegisterDevice(context.Background(), 1, DeviceRegistration{
		InstallationID:        "erke-limit-installation",
		ToolNames:             []string{"device.erke.ensure_fresh_overview"},
		BridgeProtocolVersion: 2,
	}); err != nil {
		t.Fatal(err)
	}
	job, err := service.CreateJob(context.Background(), CreateDeviceJobRequest{
		UserID: 1, RunID: "run-erke-limit", ToolCallID: "call-erke-limit",
		ToolName:          "device.erke.ensure_fresh_overview",
		Arguments:         json.RawMessage(`{"max_age_seconds":1800,"allow_upload":true}`),
		RequiredDataTypes: []string{"erke"},
		ExpiresAt:         now.Add(time.Minute),
	})
	require.NoError(t, err)
	claimed, err := service.ClaimJob(context.Background(), 1, "erke-limit-installation", job.ID, 0)
	require.NoError(t, err)

	overlong := json.RawMessage(`{
		"data":{"earned_total":40.75,"required_total":40,"unmet_categories":[],"activity_count":50,"latest_activity_date":"2026.05.26-2026.05.27 补充说明超出限制"},
		"source":"remote_edu_fetch",
		"fetched_at":"2026-07-25T09:00:00Z",
		"expires_at":"2026-07-25T09:30:00Z",
		"is_stale":false,
		"is_partial":false,
		"warnings":[],
		"evidence":[{"source":"remote_edu_fetch","fetched_at":"2026-07-25T09:00:00Z","expires_at":"2026-07-25T09:30:00Z","is_stale":false}],
		"freshness":{"before":"stale","after":"fresh"},
		"refresh_performed":true
	}`)
	_, err = service.CompleteJob(context.Background(), 1, "erke-limit-installation", job.ID, claimed.StateVersion, overlong)
	assertDeviceJobCode(t, err, "invalid_tool_result")
}

func TestDeviceJobClaimAndCompleteRequireFreshStateVersion(t *testing.T) {
	now := time.Date(2026, 7, 25, 9, 0, 0, 0, time.UTC)
	_, service := newDeviceJobFixture(t, now)
	registerTestDevice(t, service, 1, "installation-1")
	job := createTestDeviceJob(t, service, 1, now)
	claimed, err := service.ClaimJob(context.Background(), 1, "installation-1", job.ID, 0)
	if err != nil {
		t.Fatal(err)
	}
	if claimed.Status != models.DeviceToolJobClaimed || claimed.StateVersion != 1 {
		t.Fatalf("unexpected claimed job: status=%s version=%d", claimed.Status, claimed.StateVersion)
	}
	_, err = service.CompleteJob(context.Background(), 1, "installation-1", job.ID, 0, json.RawMessage(`{"total":1}`))
	assertDeviceJobCode(t, err, "state_version_conflict")
	_, err = service.CompleteJob(context.Background(), 1, "installation-1", job.ID, 1, json.RawMessage(`{"user_id":1}`))
	assertDeviceJobCode(t, err, "invalid_tool_result")
	_, err = service.CompleteJob(context.Background(), 1, "installation-1", job.ID, 1, json.RawMessage(`{"total":1}`))
	assertDeviceJobCode(t, err, "invalid_tool_result")
	completed, err := service.CompleteJob(context.Background(), 1, "installation-1", job.ID, 1, deviceToolTestResult())
	if err != nil {
		t.Fatal(err)
	}
	if completed.Status != models.DeviceToolJobCompleted || completed.StateVersion != 2 || completed.ResultHash == "" {
		t.Fatalf("unexpected completed job: status=%s version=%d hash=%q", completed.Status, completed.StateVersion, completed.ResultHash)
	}
}

func TestDeviceJobCreateAllowsNewAttemptAfterTerminalJob(t *testing.T) {
	now := time.Date(2026, 7, 25, 9, 0, 0, 0, time.UTC)
	db, service := newDeviceJobFixture(t, now)
	registerTestDevice(t, service, 1, "installation-1")
	first := createTestDeviceJob(t, service, 1, now)
	require.NoError(t, db.Model(&models.DeviceToolJob{}).
		Where("id = ?", first.ID).
		Updates(map[string]interface{}{
			"status":       models.DeviceToolJobCompleted,
			"result_json":  datatypes.JSON(deviceToolTestResult()),
			"completed_at": now,
		}).Error)

	second, err := service.CreateJob(context.Background(), CreateDeviceJobRequest{
		UserID: 1, RunID: "run-1", ToolCallID: "call-1", ToolName: "device.academic.get_cached_overview",
		Arguments: json.RawMessage(`{}`), RequiredDataTypes: []string{"academic"}, ExpiresAt: now.Add(time.Minute),
	})
	require.NoError(t, err)
	require.NotEqual(t, first.ID, second.ID, "completed device job must not be reused for a new wait cycle")

	var jobs []models.DeviceToolJob
	require.NoError(t, db.Where("run_id = ? AND tool_call_id = ?", "run-1", "call-1").Find(&jobs).Error)
	require.Len(t, jobs, 2)
}

func TestDeviceJobCreateSelectsOnlyDeviceThatSupportsTool(t *testing.T) {
	now := time.Date(2026, 7, 25, 9, 0, 0, 0, time.UTC)
	_, service := newDeviceJobFixture(t, now)
	_, err := service.RegisterDevice(context.Background(), 1, DeviceRegistration{
		InstallationID:        "overview-only",
		ToolNames:             []string{"device.academic.get_cached_overview"},
		BridgeProtocolVersion: 2,
	})
	if err != nil {
		t.Fatal(err)
	}
	_, err = service.CreateJob(context.Background(), CreateDeviceJobRequest{
		UserID: 1, RunID: "run-1", ToolCallID: "call-1", ToolName: "device.erke.get_cached_overview",
		Arguments: json.RawMessage(`{}`), RequiredDataTypes: []string{"erke"}, ExpiresAt: now.Add(time.Minute),
	})
	assertDeviceJobCode(t, err, "device_offline")
	_, err = service.RegisterDevice(context.Background(), 1, DeviceRegistration{
		InstallationID:        "erke-enabled",
		ToolNames:             []string{"device.erke.get_cached_overview"},
		BridgeProtocolVersion: 2,
	})
	if err != nil {
		t.Fatal(err)
	}
	job, err := service.CreateJob(context.Background(), CreateDeviceJobRequest{
		UserID: 1, RunID: "run-1", ToolCallID: "call-2", ToolName: "device.erke.get_cached_overview",
		Arguments: json.RawMessage(`{}`), RequiredDataTypes: []string{"erke"}, ExpiresAt: now.Add(time.Minute),
	})
	if err != nil {
		t.Fatal(err)
	}
	if job.InstallationID != "erke-enabled" {
		t.Fatalf("job assigned to unsupported device: %s", job.InstallationID)
	}
}

func deviceToolTestResult() json.RawMessage {
	return json.RawMessage(`{
		"data":{"total_recorded_courses":1,"covered_term_count":1,"covered_terms":[{"year":"2025","semester":3,"course_count":1}],"academic_situation_available":true},
		"source":"device_encrypted_cache",
		"fetched_at":"2026-07-25T09:00:00Z",
		"expires_at":"2026-07-26T09:00:00Z",
		"is_stale":false,
		"is_partial":false,
		"warnings":[],
		"evidence":[{"source":"device_encrypted_cache","fetched_at":"2026-07-25T09:00:00Z","expires_at":"2026-07-26T09:00:00Z","is_stale":false}]
	}`)
}

func bundleDeviceToolTestResult() json.RawMessage {
	return json.RawMessage(`{
		"data":{
			"grades":{"data":{"course_count":1,"earned_credits":3,"weighted_gpa":1.5,"failed_courses":[{"course_name":"大学物理","grade":45,"credits":3}]},"source":"device_encrypted_cache","fetched_at":"2026-07-25T09:00:00Z","expires_at":"2026-07-26T09:00:00Z","is_stale":false,"is_partial":false,"warnings":[],"evidence":[{"source":"device_encrypted_cache","fetched_at":"2026-07-25T09:00:00Z","expires_at":"2026-07-26T09:00:00Z","is_stale":false}],"freshness":{"before":"stale","after":"fresh"},"refresh_performed":false},
			"academic_situation":{"data":{"total_courses":10,"passed_courses":8,"failed_courses":1,"in_progress_courses":1,"degree_total_courses":40,"degree_passed_courses":30,"degree_failed_courses":1,"degree_in_progress_courses":9,"all_gpa":3.2},"source":"device_encrypted_cache","fetched_at":"2026-07-25T09:00:00Z","expires_at":"2026-08-01T09:00:00Z","is_stale":false,"is_partial":false,"warnings":[],"evidence":[{"source":"device_encrypted_cache","fetched_at":"2026-07-25T09:00:00Z","expires_at":"2026-08-01T09:00:00Z","is_stale":false}],"freshness":{"before":"fresh","after":"fresh"},"refresh_performed":false},
			"credit_requirements":{"data":{"required_credits":160,"earned_credits":120,"completed_credits":120,"remaining_credits":40,"credit_gap":40,"module_count":4},"source":"device_encrypted_cache","fetched_at":"2026-07-25T09:00:00Z","expires_at":"2026-08-25T09:00:00Z","is_stale":false,"is_partial":false,"warnings":[],"evidence":[{"source":"device_encrypted_cache","fetched_at":"2026-07-25T09:00:00Z","expires_at":"2026-08-25T09:00:00Z","is_stale":false}],"freshness":{"before":"fresh","after":"fresh"},"refresh_performed":false}
		},
		"source":"device_encrypted_cache","fetched_at":"2026-07-25T09:00:00Z","expires_at":"2026-07-26T09:00:00Z","is_stale":false,"is_partial":false,"warnings":[],
		"evidence":[{"source":"device_encrypted_cache","fetched_at":"2026-07-25T09:00:00Z","expires_at":"2026-07-26T09:00:00Z","is_stale":false},{"source":"device_encrypted_cache","fetched_at":"2026-07-25T09:00:00Z","expires_at":"2026-08-01T09:00:00Z","is_stale":false},{"source":"device_encrypted_cache","fetched_at":"2026-07-25T09:00:00Z","expires_at":"2026-08-25T09:00:00Z","is_stale":false}],
		"freshness":{"before":"stale","after":"fresh"},"refresh_performed":false
	}`)
}

func TestDeviceJobAccountSwitchCancelsOutstandingJobs(t *testing.T) {
	now := time.Date(2026, 7, 25, 9, 0, 0, 0, time.UTC)
	db, service := newDeviceJobFixture(t, now)
	registerTestDevice(t, service, 1, "shared-installation")
	job := createTestDeviceJob(t, service, 1, now)
	if err := db.Create(&models.User{PasswordHash: "test-2"}).Error; err != nil {
		t.Fatal(err)
	}
	registerTestDevice(t, service, 2, "shared-installation")
	var stored models.DeviceToolJob
	if err := db.First(&stored, "id = ?", job.ID).Error; err != nil {
		t.Fatal(err)
	}
	if stored.Status != models.DeviceToolJobCancelled || stored.ErrorCode != "device_account_changed" {
		t.Fatalf("account switch must cancel old task: status=%s error=%s", stored.Status, stored.ErrorCode)
	}
	_, err := service.PendingJobs(context.Background(), 1, "shared-installation")
	assertDeviceJobCode(t, err, "device_not_registered")
}

func TestDeviceJobCreateRejectsIdentityInModelArguments(t *testing.T) {
	now := time.Date(2026, 7, 25, 9, 0, 0, 0, time.UTC)
	_, service := newDeviceJobFixture(t, now)
	registerTestDevice(t, service, 1, "installation-1")
	_, err := service.CreateJob(context.Background(), CreateDeviceJobRequest{
		UserID: 1, RunID: "run-1", ToolCallID: "call-1", ToolName: "device.schedule.get_cached_week",
		Arguments: json.RawMessage(`{"user_id":1}`), RequiredDataTypes: []string{"schedule"}, ExpiresAt: now.Add(time.Minute),
	})
	assertDeviceJobCode(t, err, "invalid_tool_arguments")
}

func TestDeviceJobExpiresBeforeClaim(t *testing.T) {
	now := time.Date(2026, 7, 25, 9, 0, 0, 0, time.UTC)
	_, service := newDeviceJobFixture(t, now)
	registerTestDevice(t, service, 1, "installation-1")
	job := createTestDeviceJob(t, service, 1, now)
	service.clock = func() time.Time { return now.Add(2 * time.Minute) }
	_, err := service.ClaimJob(context.Background(), 1, "installation-1", job.ID, 0)
	assertDeviceJobCode(t, err, "job_expired")
}

func TestDeviceJobScheduleBindsResultToRequestedWeek(t *testing.T) {
	now := time.Date(2026, 9, 14, 9, 0, 0, 0, time.UTC)
	_, service := newDeviceJobFixture(t, now)
	_, err := service.RegisterDevice(context.Background(), 1, DeviceRegistration{
		InstallationID: "schedule-v2", ToolNames: []string{"device.schedule.get_cached_week"}, BridgeProtocolVersion: 2,
	})
	if err != nil {
		t.Fatal(err)
	}
	_, err = service.CreateJob(context.Background(), CreateDeviceJobRequest{
		UserID: 1, RunID: "run-1", ToolCallID: "call-missing", ToolName: "device.schedule.get_cached_week",
		Arguments: json.RawMessage(`{}`), RequiredDataTypes: []string{"schedule"}, ExpiresAt: now.Add(time.Minute),
	})
	assertDeviceJobCode(t, err, "invalid_tool_arguments")
	job, err := service.CreateJob(context.Background(), CreateDeviceJobRequest{
		UserID: 1, RunID: "run-1", ToolCallID: "call-1", ToolName: "device.schedule.get_cached_week",
		Arguments: json.RawMessage(`{"week_containing":"2026-09-14"}`), RequiredDataTypes: []string{"schedule"}, ExpiresAt: now.Add(time.Minute),
	})
	if err != nil {
		t.Fatal(err)
	}
	claimed, err := service.ClaimJob(context.Background(), 1, "schedule-v2", job.ID, 0)
	if err != nil {
		t.Fatal(err)
	}
	_, err = service.CompleteJob(context.Background(), 1, "schedule-v2", job.ID, claimed.StateVersion, scheduleToolTestResult("2026-09-21", "2026-09-27", "2026-09-21"))
	assertDeviceJobCode(t, err, "invalid_tool_result")
	completed, err := service.CompleteJob(context.Background(), 1, "schedule-v2", job.ID, claimed.StateVersion, scheduleToolTestResult("2026-09-14", "2026-09-20", "2026-09-14"))
	if err != nil || completed.Status != models.DeviceToolJobCompleted {
		t.Fatalf("expected requested week completion, job=%#v err=%v", completed, err)
	}
}

func TestDeviceJobAcceptsMinimalPhysicalOverview(t *testing.T) {
	_, service := newDeviceJobFixture(t, time.Now().UTC())
	_, err := service.RegisterDevice(context.Background(), 1, DeviceRegistration{
		InstallationID: "physical-installation", ToolNames: []string{"device.physical.get_cached_overview"},
		BridgeProtocolVersion: requiredDeviceBridgeVersion, ClientVersion: "1.0.0",
	})
	require.NoError(t, err)
	job, err := service.CreateJob(context.Background(), CreateDeviceJobRequest{
		UserID: 1, RunID: "physical-run", ToolCallID: "physical-call",
		ToolName: "device.physical.get_cached_overview", Arguments: json.RawMessage(`{}`),
		RequiredDataTypes: []string{"physical"}, ExpiresAt: time.Now().UTC().Add(time.Minute),
	})
	require.NoError(t, err)
	claimed, err := service.ClaimJob(context.Background(), 1, "physical-installation", job.ID, job.StateVersion)
	require.NoError(t, err)
	completed, err := service.CompleteJob(context.Background(), 1, "physical-installation", job.ID, claimed.StateVersion, json.RawMessage(`{
		"data":{"latest_year":"2026","available_year_count":1,"total_grade":"良好","total_score":82.5,"metrics":[{"name":"50 米跑","result":"7.2 秒","grade":"良好","score":82}]},
		"source":"device_encrypted_cache","fetched_at":"2026-08-28T00:00:00Z","expires_at":"2026-09-27T00:00:00Z","is_stale":false,"is_partial":false,"warnings":[],
		"evidence":[{"source":"device_encrypted_cache","fetched_at":"2026-08-28T00:00:00Z","expires_at":"2026-09-27T00:00:00Z","is_stale":false}]
	}`))
	require.NoError(t, err)
	require.Equal(t, models.DeviceToolJobCompleted, completed.Status)
}

func TestDeviceJobIgnoresStaleAndOutdatedDevices(t *testing.T) {
	now := time.Date(2026, 7, 25, 9, 0, 0, 0, time.UTC)
	db, service := newDeviceJobFixture(t, now)
	stale, err := service.RegisterDevice(context.Background(), 1, DeviceRegistration{
		InstallationID: "stale-v2", ToolNames: []string{"device.schedule.get_cached_week"}, BridgeProtocolVersion: 2,
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := db.Model(stale).Update("last_seen_at", now.Add(-deviceOnlineTTL-time.Second)).Error; err != nil {
		t.Fatal(err)
	}
	request := CreateDeviceJobRequest{UserID: 1, RunID: "run-1", ToolCallID: "call-1", ToolName: "device.schedule.get_cached_week", Arguments: json.RawMessage(`{"week_containing":"2026-07-20"}`), RequiredDataTypes: []string{"schedule"}, ExpiresAt: now.Add(time.Minute)}
	_, err = service.CreateJob(context.Background(), request)
	assertDeviceJobCode(t, err, "device_offline")
	_, err = service.RegisterDevice(context.Background(), 1, DeviceRegistration{
		InstallationID: "legacy-v1", ToolNames: []string{"device.schedule.get_cached_week"}, BridgeProtocolVersion: 1,
	})
	if err != nil {
		t.Fatal(err)
	}
	_, err = service.CreateJob(context.Background(), request)
	assertDeviceJobCode(t, err, "device_client_outdated")
}

func scheduleToolTestResult(weekStart, weekEnd, courseDate string) json.RawMessage {
	return json.RawMessage(`{"data":{"week_start":"` + weekStart + `","week_end":"` + weekEnd + `","courses":[{"date":"` + courseDate + `","course_name":"高等数学","start_section":1,"end_section":2}]},"source":"device_encrypted_cache","fetched_at":"2026-09-14T09:00:00Z","expires_at":"2026-09-15T09:00:00Z","is_stale":false,"is_partial":false,"warnings":[],"evidence":[{"source":"device_encrypted_cache","fetched_at":"2026-09-14T09:00:00Z","expires_at":"2026-09-15T09:00:00Z","is_stale":false}]}`)
}

func assertDeviceJobCode(t *testing.T, err error, expected string) {
	t.Helper()
	if err == nil {
		t.Fatalf("expected %s, got nil", expected)
	}
	var deviceErr *DeviceJobError
	if !errors.As(err, &deviceErr) || deviceErr.Code != expected {
		t.Fatalf("expected %s, got %v", expected, err)
	}
}

func seedWaitForUserRun(t *testing.T, db *gorm.DB, runID string, userID uint, expiresAt time.Time) {
	t.Helper()
	if err := db.Create(&models.AIRun{
		ID: runID, UserID: userID, ConversationID: "conv-" + runID, ClientRequestID: "req-" + runID,
		State: models.AIRunStateWaitingDevice, Provider: "mock", Model: "mock",
		MessageHash: "hash-" + runID, ExpiresAt: expiresAt,
		AgentContext: datatypes.JSON("{}"), AgentStateJSON: datatypes.JSON("{}"),
	}).Error; err != nil {
		t.Fatal(err)
	}
}

func TestDeviceJobWaitForUserExtendsExpiryToRunBudget(t *testing.T) {
	now := time.Date(2026, 7, 25, 9, 0, 0, 0, time.UTC)
	db, service := newDeviceJobFixture(t, now)
	registerTestDevice(t, service, 1, "wait-installation")
	job := createTestDeviceJob(t, service, 1, now)
	runExpiresAt := now.Add(10 * time.Minute)
	seedWaitForUserRun(t, db, "run-1", 1, runExpiresAt)

	claimed, err := service.ClaimJob(context.Background(), 1, "wait-installation", job.ID, job.StateVersion)
	if err != nil {
		t.Fatal(err)
	}
	waiting, err := service.WaitForUserJob(context.Background(), 1, "wait-installation", job.ID, claimed.StateVersion)
	if err != nil {
		t.Fatal(err)
	}
	if waiting.Status != models.DeviceToolJobWaitingUser || waiting.StateVersion != claimed.StateVersion+1 {
		t.Fatalf("unexpected waiting job: status=%s version=%d", waiting.Status, waiting.StateVersion)
	}
	if !waiting.ExpiresAt.Equal(runExpiresAt) {
		t.Fatalf("expected expiry extended to run budget %v, got %v", runExpiresAt, waiting.ExpiresAt)
	}

	// 幂等：当前版本重复上报直接返回，不推进状态版本。
	again, err := service.WaitForUserJob(context.Background(), 1, "wait-installation", job.ID, waiting.StateVersion)
	if err != nil {
		t.Fatal(err)
	}
	if again.StateVersion != waiting.StateVersion {
		t.Fatalf("expected idempotent state version %d, got %d", waiting.StateVersion, again.StateVersion)
	}
	// 响应丢失后的重试带着旧版本也能幂等取回当前任务。
	retried, err := service.WaitForUserJob(context.Background(), 1, "wait-installation", job.ID, waiting.StateVersion-1)
	if err != nil {
		t.Fatal(err)
	}
	if retried.StateVersion != waiting.StateVersion || retried.Status != models.DeviceToolJobWaitingUser {
		t.Fatalf("unexpected retry result: status=%s version=%d", retried.Status, retried.StateVersion)
	}
}

func TestDeviceJobWaitForUserRejectsPendingJob(t *testing.T) {
	now := time.Date(2026, 7, 25, 9, 0, 0, 0, time.UTC)
	db, service := newDeviceJobFixture(t, now)
	registerTestDevice(t, service, 1, "wait-pending")
	job := createTestDeviceJob(t, service, 1, now)
	seedWaitForUserRun(t, db, "run-1", 1, now.Add(10*time.Minute))

	_, err := service.WaitForUserJob(context.Background(), 1, "wait-pending", job.ID, job.StateVersion)
	assertDeviceJobCode(t, err, "invalid_job_state")
}

func TestDeviceJobWaitForUserExpiresWithRunBudget(t *testing.T) {
	now := time.Date(2026, 7, 25, 9, 0, 0, 0, time.UTC)
	db, service := newDeviceJobFixture(t, now)
	registerTestDevice(t, service, 1, "wait-expired")
	job := createTestDeviceJob(t, service, 1, now)
	seedWaitForUserRun(t, db, "run-1", 1, now.Add(-time.Second))

	claimed, err := service.ClaimJob(context.Background(), 1, "wait-expired", job.ID, job.StateVersion)
	if err != nil {
		t.Fatal(err)
	}
	_, err = service.WaitForUserJob(context.Background(), 1, "wait-expired", job.ID, claimed.StateVersion)
	assertDeviceJobCode(t, err, "job_expired")
	// 事务回滚后任务保持原状，继续走自身 expires_at 的惰性过期。
	var refreshed models.DeviceToolJob
	if err := db.Where("id = ?", job.ID).First(&refreshed).Error; err != nil {
		t.Fatal(err)
	}
	if refreshed.Status != models.DeviceToolJobClaimed {
		t.Fatalf("expected claimed job preserved, got %s", refreshed.Status)
	}
}

func TestDeviceJobWaitForUserExpiresStaleJob(t *testing.T) {
	now := time.Date(2026, 7, 25, 9, 0, 0, 0, time.UTC)
	db, service := newDeviceJobFixture(t, now)
	registerTestDevice(t, service, 1, "wait-stale")
	job := createTestDeviceJob(t, service, 1, now)
	seedWaitForUserRun(t, db, "run-1", 1, now.Add(10*time.Minute))

	later := now.Add(2 * time.Minute)
	service.clock = func() time.Time { return later }
	_, err := service.WaitForUserJob(context.Background(), 1, "wait-stale", job.ID, job.StateVersion)
	assertDeviceJobCode(t, err, "job_expired")
	// 持久化标记由 PendingJobs 的 expireDue 兜底完成。
	if _, err := service.PendingJobs(context.Background(), 1, "wait-stale"); err != nil {
		t.Fatal(err)
	}
	var refreshed models.DeviceToolJob
	if err := db.Where("id = ?", job.ID).First(&refreshed).Error; err != nil {
		t.Fatal(err)
	}
	if refreshed.Status != models.DeviceToolJobExpired || refreshed.ErrorCode != "job_expired" {
		t.Fatalf("expected lazily expired job, got status=%s code=%s", refreshed.Status, refreshed.ErrorCode)
	}
}

// 复现生产故障：任务创建时绑定到随后静默的 installation，实际轮询的是同账号
// 的另一个安装。未领取的 pending 任务必须能被新安装看到、认领并重绑。
func TestPendingJobsDeliversUnclaimedJobToNewInstallation(t *testing.T) {
	now := time.Date(2026, 7, 25, 9, 0, 0, 0, time.UTC)
	_, service := newDeviceJobFixture(t, now)
	registerTestDevice(t, service, 1, "stale-installation")
	job := createTestDeviceJob(t, service, 1, now)
	if job.InstallationID != "stale-installation" {
		t.Fatalf("job bound to unexpected installation: %s", job.InstallationID)
	}
	registerTestDevice(t, service, 1, "fresh-installation")

	pending, err := service.PendingJobs(context.Background(), 1, "fresh-installation")
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, candidate := range pending {
		if candidate.ID == job.ID {
			found = true
		}
	}
	if !found {
		t.Fatalf("new installation must see the unclaimed job, got %d jobs", len(pending))
	}

	claimed, err := service.ClaimJob(context.Background(), 1, "fresh-installation", job.ID, job.StateVersion)
	if err != nil {
		t.Fatal(err)
	}
	if claimed.InstallationID != "fresh-installation" || claimed.Status != models.DeviceToolJobClaimed {
		t.Fatalf("takeover must rebind installation: installation=%s status=%s", claimed.InstallationID, claimed.Status)
	}
	completed, err := service.CompleteJob(context.Background(), 1, "fresh-installation", job.ID, claimed.StateVersion, deviceToolTestResult())
	if err != nil {
		t.Fatal(err)
	}
	if completed.Status != models.DeviceToolJobCompleted {
		t.Fatalf("expected completed job, got %s", completed.Status)
	}
}

func TestPendingJobsHidesOrphanedJobFromDeviceWithoutTool(t *testing.T) {
	now := time.Date(2026, 7, 25, 9, 0, 0, 0, time.UTC)
	_, service := newDeviceJobFixture(t, now)
	if _, err := service.RegisterDevice(context.Background(), 1, DeviceRegistration{
		InstallationID:        "freshness-holder",
		ToolNames:             []string{"device.academic.ensure_fresh_overview"},
		BridgeProtocolVersion: 2,
	}); err != nil {
		t.Fatal(err)
	}
	job, err := service.CreateJob(context.Background(), CreateDeviceJobRequest{
		UserID: 1, RunID: "run-1", ToolCallID: "call-fresh", ToolName: "device.academic.ensure_fresh_overview",
		Arguments: json.RawMessage(`{"max_age_seconds":300}`), RequiredDataTypes: []string{"academic"}, ExpiresAt: now.Add(time.Minute),
	})
	if err != nil {
		t.Fatal(err)
	}
	registerTestDevice(t, service, 1, "academic-only")

	pending, err := service.PendingJobs(context.Background(), 1, "academic-only")
	if err != nil {
		t.Fatal(err)
	}
	for _, candidate := range pending {
		if candidate.ID == job.ID {
			t.Fatal("device without the tool must not see the orphaned job")
		}
	}
	_, err = service.ClaimJob(context.Background(), 1, "academic-only", job.ID, job.StateVersion)
	assertDeviceJobCode(t, err, "tool_not_allowed")
}

func TestClaimJobRejectsTakeoverOfClaimedJob(t *testing.T) {
	now := time.Date(2026, 7, 25, 9, 0, 0, 0, time.UTC)
	_, service := newDeviceJobFixture(t, now)
	registerTestDevice(t, service, 1, "first-installation")
	job := createTestDeviceJob(t, service, 1, now)
	claimed, err := service.ClaimJob(context.Background(), 1, "first-installation", job.ID, job.StateVersion)
	if err != nil {
		t.Fatal(err)
	}
	registerTestDevice(t, service, 1, "second-installation")
	_, err = service.ClaimJob(context.Background(), 1, "second-installation", job.ID, claimed.StateVersion)
	assertDeviceJobCode(t, err, "invalid_job_state")
}
