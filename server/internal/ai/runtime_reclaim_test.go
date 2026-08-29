package ai

import (
	"context"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	"gorm.io/datatypes"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

func seedReclaimRun(t *testing.T, db *gorm.DB, runID string, userID uint, state string) {
	t.Helper()
	require.NoError(t, db.Create(&models.AIRun{
		ID: runID, UserID: userID, ConversationID: "conv-" + runID, ClientRequestID: "req-" + runID,
		State: state, Provider: "mock", Model: "mock",
		MessageHash: "hash-" + runID, ExpiresAt: time.Now().Add(10 * time.Minute),
		AgentContext: datatypes.JSON("{}"), AgentStateJSON: datatypes.JSON("{}"),
	}).Error)
	require.NoError(t, db.Create(&models.AIBudgetReservation{
		ID: "resv-" + runID, RunID: runID, UserID: userID, ReservedMicroYuan: 10_000,
		Status: "reserved", ExpiresAt: time.Now().Add(-time.Minute),
	}).Error)
}

// 预算回收不能强杀还有活跃设备任务的 Run：用户可能正在输入凭据，
// 输完密码回传结果必须还能落到同一个 Run 上。
func TestReclaimExpiredReservationsKeepsRunsWithActiveDeviceJobs(t *testing.T) {
	db := newRuntimeTestDB(t)
	runtime := newTestRuntime(t, db, &staticEventProvider{}, fixedRetriever{})

	seedReclaimRun(t, db, "run-reclaim-wait", 1, models.AIRunStateWaitingDevice)
	require.NoError(t, db.Create(&models.DeviceToolJob{
		ID: "job-wait", UserID: 1, RunID: "run-reclaim-wait", ToolCallID: "call-wait",
		InstallationID: "inst-1", ToolName: "device.erke.ensure_fresh_overview",
		ArgumentsJSON: datatypes.JSON(`{"max_age_seconds":300,"allow_upload":false}`),
		RequiredDataTypes: datatypes.JSON(`["erke"]`), Status: models.DeviceToolJobWaitingUser,
		ExpiresAt: time.Now().Add(5 * time.Minute),
	}).Error)
	require.NoError(t, runtime.ReclaimExpiredReservations(context.Background()))

	var preserved models.AIRun
	require.NoError(t, db.First(&preserved, "id = ?", "run-reclaim-wait").Error)
	require.Equal(t, models.AIRunStateWaitingDevice, preserved.State)

	// 没有活跃设备任务的 Run 仍按原语义回收。
	seedReclaimRun(t, db, "run-reclaim-gone", 2, models.AIRunStateGenerating)
	require.NoError(t, runtime.ReclaimExpiredReservations(context.Background()))
	var reclaimed models.AIRun
	require.NoError(t, db.First(&reclaimed, "id = ?", "run-reclaim-gone").Error)
	require.Equal(t, models.AIRunStateExpired, reclaimed.State)
}
