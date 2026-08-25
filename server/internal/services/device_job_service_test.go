package services

import (
	"context"
	"encoding/json"
	"errors"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	"gorm.io/driver/sqlite"
	"gorm.io/datatypes"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

func newDeviceJobFixture(t *testing.T, now time.Time) (*gorm.DB, *DeviceJobService) {
	t.Helper()
	db, err := gorm.Open(sqlite.Open("file:"+t.Name()+"?mode=memory&cache=shared"), &gorm.Config{})
	if err != nil {
		t.Fatal(err)
	}
	if err := db.AutoMigrate(&models.User{}, &models.UserDevice{}, &models.DeviceToolJob{}); err != nil {
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
		ToolNames:             []string{"device.academic.get_cached_overview", "device.academic.ensure_fresh_grade_summary", "device.academic.ensure_fresh_risk_context", "device.schedule.get_cached_week", "device.academic.get_credit_summary", "device.erke.get_cached_overview"},
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
