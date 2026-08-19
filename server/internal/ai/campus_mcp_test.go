package ai

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"shenliyuan/internal/academic"
	"shenliyuan/internal/models"
)

type fixedPersonalSnapshotReader struct {
	lookup academic.SnapshotLookup
	err    error
}

type academicAnalysisSnapshotReader struct {
	results map[academic.DatasetType]academic.ContextResult
}

func (reader academicAnalysisSnapshotReader) CurrentCredentialGeneration(context.Context, uint) (uint, error) {
	return 1, nil
}

func (reader academicAnalysisSnapshotReader) LookupLatest(_ context.Context, _ uint, dataset academic.DatasetType, _ uint) (academic.SnapshotLookup, error) {
	result, ok := reader.results[dataset]
	if !ok {
		return academic.SnapshotLookup{}, nil
	}
	return academic.SnapshotLookup{Found: true, Result: result}, nil
}

func (reader fixedPersonalSnapshotReader) LookupErke(context.Context, uint) (academic.SnapshotLookup, error) {
	return reader.lookup, reader.err
}

type fixedPersonalDataPermissionReader map[models.AIUserPermissionScope]models.AIUserPermissionPolicy

func (reader fixedPersonalDataPermissionReader) Policy(_ context.Context, _ uint, scope models.AIUserPermissionScope) (models.AIUserPermissionPolicy, error) {
	if policy, found := reader[scope]; found {
		return policy, nil
	}
	return models.AIUserPermissionAsk, nil
}

func campusToolByName(t *testing.T, tools []PureReadTool, name string) PureReadTool {
	t.Helper()
	for _, tool := range tools {
		if tool.Name() == name {
			return tool
		}
	}
	t.Fatalf("tool %q not found", name)
	return nil
}

func TestCampusMCPSearchPolicySplitsModelKeywordQuery(t *testing.T) {
	db := newRuntimeTestDB(t)
	require.NoError(t, db.AutoMigrate(&models.AIKnowledgeDocument{}))
	publishedAt := time.Date(2026, 7, 20, 9, 0, 0, 0, time.UTC)
	require.NoError(t, db.Create(&models.AIKnowledgeDocument{
		Title: "本科生成绩管理办法", SourceType: "manual", DocumentType: "policy",
		Content: "平均学分绩点按课程学分加权计算。", ContentHash: "published", Status: models.KnowledgeStatusPublished,
		PublishedAt: &publishedAt,
	}).Error)
	require.NoError(t, db.Create(&models.AIKnowledgeDocument{
		Title: "未发布草稿", SourceType: "manual", DocumentType: "policy",
		Content: "GPA 草稿内容", ContentHash: "draft", Status: models.KnowledgeStatusDraft,
	}).Error)

	mcp := &campusMCP{db: db, now: func() time.Time { return publishedAt }}
	result, err := mcp.searchPolicy(context.Background(), 7, json.RawMessage(`{"query":"GPA 平均学分绩点 绩点","limit":10}`))
	require.NoError(t, err)
	envelope := result.(CampusToolResult)
	items := envelope.Data.([]knowledgeItem)
	require.Len(t, items, 1)
	require.Equal(t, "本科生成绩管理办法", items[0].Title)
}

func TestCampusMCPErkeUsesUploadedSnapshotWithoutAcademicCredential(t *testing.T) {
	now := time.Date(2026, 7, 25, 9, 0, 0, 0, time.UTC)
	reader := fixedPersonalSnapshotReader{lookup: academic.SnapshotLookup{
		Found: true,
		Result: academic.ContextResult{
			Data:      json.RawMessage(`{"earned_total":42.5,"required_total":60,"unmet_categories":[{"name":"创新创业","gap":4}]}`),
			Status:    academic.DataStatusAvailable,
			Source:    academic.DataSourceUserUploadedSnapshot,
			FetchedAt: &now,
			Warnings:  make([]string, 0),
			Evidence: []academic.Evidence{{
				Source: academic.DataSourceUserUploadedSnapshot, Dataset: academic.DatasetErke, FetchedAt: &now,
			}},
		},
	}}
	tools := NewCampusMCPTools(nil, nil, reader,
		WithCampusPersonalDataPermissionReader(AllowAllPermissionReader{}))
	result, err := campusToolByName(t, tools, "erke.get_overview").Execute(context.Background(), 7, json.RawMessage(`{}`))
	require.NoError(t, err)
	envelope, ok := result.(CampusToolResult)
	require.True(t, ok)
	require.Equal(t, academic.DataSourceUserUploadedSnapshot, envelope.Source)
	require.Equal(t, academic.DataStatusAvailable, envelope.Status)
	require.Equal(t, 42.5, envelope.Data.(map[string]interface{})["earned_total"])

	resolved, err := campusToolByName(t, tools, "academic.resolve_context").Execute(context.Background(), 7, json.RawMessage(`{"datasets":["erke"],"freshness":"prefer_recent","reason":"erke_overview"}`))
	require.NoError(t, err)
	resolvedEnvelope := resolved.(CampusToolResult)
	require.Equal(t, academic.DataSourceUserUploadedSnapshot, resolvedEnvelope.Data.(map[string]academic.ContextResult)["erke"].Source)
}

func TestCampusMCPErkeOverviewReadsStructuredUploadedSnapshot(t *testing.T) {
	reader := fixedPersonalSnapshotReader{lookup: academic.SnapshotLookup{
		Found: true,
		Result: academic.ContextResult{
			Data: json.RawMessage(`{
				"graduation":{"earned_total":42.5,"required_total":60,"graduation_gap":17.5,"unmet_categories":[{"name":"创新创业","gap":4}]},
				"yearly":{"year":"2025-2026","yearly_gap":4},
				"recent_activities":[{"category":"创新创业","score":1.5,"date":"2026-07-25"}]
			}`),
			Status:   academic.DataStatusAvailable,
			Source:   academic.DataSourceUserUploadedSnapshot,
			Warnings: make([]string, 0),
			Evidence: make([]academic.Evidence, 0),
		},
	}}
	tools := NewCampusMCPTools(nil, nil, reader,
		WithCampusPersonalDataPermissionReader(AllowAllPermissionReader{}))
	result, err := campusToolByName(t, tools, "erke.get_overview").Execute(context.Background(), 7, json.RawMessage(`{}`))
	require.NoError(t, err)
	overview := result.(CampusToolResult).Data.(map[string]interface{})
	require.Equal(t, 42.5, overview["earned_total"])
	require.Equal(t, 60.0, overview["required_total"])
	require.Equal(t, "2025-2026", overview["year"])
	require.Equal(t, 1, overview["activity_count"])
}

func TestCampusMCPNeverPolicyBlocksSnapshotsAndDeviceJobs(t *testing.T) {
	permissions := fixedPersonalDataPermissionReader{
		models.AIUserPermissionPersonalDataAccess: models.AIUserPermissionNever,
	}
	mcp := &campusMCP{permissions: permissions}
	results, wait, err := mcp.resolveSnapshots(context.Background(), 7, academic.ResolveContextRequest{
		Datasets:  []academic.DatasetType{academic.DatasetGrades},
		Freshness: academic.FreshnessPreferRecent,
		Reason:    "failure_risk",
	})
	require.NoError(t, err)
	require.Nil(t, wait)
	require.Equal(t, academic.DataStatusPermissionRequired, results[academic.DatasetGrades].Status)

	deviceJobs := 0
	mcp.permissions = fixedPersonalDataPermissionReader{
		models.AIUserPermissionDeviceCacheAccess: models.AIUserPermissionNever,
	}
	mcp.deviceJobs = DeviceJobSchedulerFunc(func(context.Context, DeviceJobRequest) (DeviceJobReference, error) {
		deviceJobs++
		return DeviceJobReference{ID: "device-job"}, nil
	})
	results = map[academic.DatasetType]academic.ContextResult{
		academic.DatasetSchedule: personalContextUnavailable(academic.DataStatusMissing, "服务端没有可用快照"),
	}
	wait = mcp.waitForPersonalContext(
		withToolCallContext(context.Background(), "run-1", "call-1", 7, "academic.resolve_context"),
		7,
		academic.ResolveContextRequest{Datasets: []academic.DatasetType{academic.DatasetSchedule}, Reason: "schedule_availability"},
		results,
	)
	require.Nil(t, wait)
	require.Zero(t, deviceJobs)
	require.Equal(t, academic.DataStatusPermissionRequired, results[academic.DatasetSchedule].Status)
}

func TestCampusMCPScheduleDeviceJobUsesRequestedWeek(t *testing.T) {
	var scheduled DeviceJobRequest
	mcp := &campusMCP{
		permissions: fixedPersonalDataPermissionReader{models.AIUserPermissionDeviceCacheAccess: models.AIUserPermissionAlways},
		deviceJobs: DeviceJobSchedulerFunc(func(_ context.Context, request DeviceJobRequest) (DeviceJobReference, error) {
			scheduled = request
			return DeviceJobReference{ID: "device-job"}, nil
		}),
	}
	results := map[academic.DatasetType]academic.ContextResult{
		academic.DatasetSchedule: personalContextUnavailable(academic.DataStatusMissing, "服务端没有可用快照"),
	}
	wait := mcp.waitForPersonalContext(
		withToolCallContext(context.Background(), "run-1", "call-1", 7, "schedule.get_availability"),
		7,
		academic.ResolveContextRequest{
			Datasets: []academic.DatasetType{academic.DatasetSchedule}, Reason: "schedule_availability",
			ScheduleWeekContaining: "2026-09-14",
		},
		results,
	)
	require.NotNil(t, wait)
	require.Equal(t, "device.schedule.get_cached_week", scheduled.ToolName)
	require.JSONEq(t, `{"week_containing":"2026-09-14"}`, string(scheduled.Arguments))
}

func TestCampusMCPPermissionFailureIsNotReportedAsUserDenial(t *testing.T) {
	mcp := &campusMCP{}
	results, wait, err := mcp.resolveSnapshots(context.Background(), 7, academic.ResolveContextRequest{
		Datasets: []academic.DatasetType{academic.DatasetGrades}, Freshness: academic.FreshnessPreferRecent, Reason: "grade_summary",
	})
	require.NoError(t, err)
	require.Nil(t, wait)
	require.Equal(t, academic.DataStatusFailed, results[academic.DatasetGrades].Status)
	require.Contains(t, results[academic.DatasetGrades].Warnings, "权限服务暂时不可用，请稍后重试")
}

func TestCampusMCPAcademicRiskAnalysisKeepsObservedRiskAndCoverageBoundary(t *testing.T) {
	reader := academicAnalysisSnapshotReader{results: map[academic.DatasetType]academic.ContextResult{
		academic.DatasetGrades: {
			Data:   json.RawMessage(`{"grades":[{"course_name":"大学物理B2","credits":3,"fraction":45}]}`),
			Status: academic.DataStatusAvailable, Source: academic.DataSourceServerSnapshot,
		},
		academic.DatasetCreditRequirements: {
			Data:   json.RawMessage(`{"earned_credits":30.5,"required_credits":30.5}`),
			Status: academic.DataStatusAvailable, Source: academic.DataSourceServerSnapshot,
		},
		academic.DatasetAcademicSituation: {
			Data:   json.RawMessage(`{"earned_credits":30.5,"required_credits":30.5}`),
			Status: academic.DataStatusAvailable, Source: academic.DataSourceServerSnapshot,
		},
		academic.DatasetErke: {
			Data:   json.RawMessage(`{"graduation_gap":0}`),
			Status: academic.DataStatusAvailable, Source: academic.DataSourceServerSnapshot,
		},
	}}
	tools := NewCampusMCPTools(newRuntimeTestDB(t), reader, nil,
		WithCampusPersonalDataPermissionReader(AllowAllPermissionReader{}))
	value, err := campusToolByName(t, tools, "academic.get_risk_analysis").Execute(
		context.Background(), 7, json.RawMessage(`{}`),
	)
	require.NoError(t, err)
	envelope := value.(CampusToolResult)
	data := envelope.Data.(map[string]interface{})
	require.Equal(t, "incomplete", data["risk_level"])
	require.Contains(t, data["risks"], "发现 1 门未通过课程（大学物理B2）")
	require.Equal(t, 3, data["available_dataset_count"])
}

type countingAcademicSnapshotReader struct {
	generationCalls int
	lookupCalls     int
}

func (reader *countingAcademicSnapshotReader) CurrentCredentialGeneration(context.Context, uint) (uint, error) {
	reader.generationCalls++
	return 1, nil
}

func (reader *countingAcademicSnapshotReader) LookupLatest(context.Context, uint, academic.DatasetType, uint) (academic.SnapshotLookup, error) {
	reader.lookupCalls++
	return academic.SnapshotLookup{Found: true, Result: academic.ContextResult{
		Data: json.RawMessage(`{"grades":[]}`), Status: academic.DataStatusAvailable, Source: academic.DataSourceServerSnapshot,
	}}, nil
}

func TestCampusMCPAskWaitsBeforeReadingSnapshots(t *testing.T) {
	reader := &countingAcademicSnapshotReader{}
	mcp := &campusMCP{
		db: newRuntimeTestDB(t), snapshots: reader, permissions: fixedPersonalDataPermissionReader{}, now: time.Now,
	}
	ctx := withToolCallContext(context.Background(), "run-ask", "call-ask", 7, "academic.get_grade_summary")
	results, wait, err := mcp.resolveSnapshots(ctx, 7, academic.ResolveContextRequest{
		Datasets: []academic.DatasetType{academic.DatasetGrades}, Freshness: academic.FreshnessPreferRecent, Reason: "grade_summary",
	})
	require.NoError(t, err)
	require.Nil(t, results)
	require.NotNil(t, wait)
	require.Equal(t, models.AIUserPermissionPersonalDataAccess, wait.ConsentScope)
	require.Zero(t, reader.generationCalls)
	require.Zero(t, reader.lookupCalls)
}

func TestCampusMCPAlwaysReadsAndNeverDoesNotReadSnapshots(t *testing.T) {
	reader := &countingAcademicSnapshotReader{}
	permissions := fixedPersonalDataPermissionReader{
		models.AIUserPermissionPersonalDataAccess:   models.AIUserPermissionAlways,
		models.AIUserPermissionAcademicCloudStorage: models.AIUserPermissionAlways,
	}
	mcp := &campusMCP{snapshots: reader, permissions: permissions, now: time.Now}
	results, wait, err := mcp.resolveSnapshots(context.Background(), 7, academic.ResolveContextRequest{
		Datasets: []academic.DatasetType{academic.DatasetGrades}, Freshness: academic.FreshnessPreferRecent, Reason: "grade_summary",
	})
	require.NoError(t, err)
	require.Nil(t, wait)
	require.Equal(t, academic.DataStatusAvailable, results[academic.DatasetGrades].Status)
	require.Equal(t, 1, reader.generationCalls)
	require.Equal(t, 1, reader.lookupCalls)

	reader.generationCalls = 0
	reader.lookupCalls = 0
	mcp.permissions = fixedPersonalDataPermissionReader{
		models.AIUserPermissionPersonalDataAccess: models.AIUserPermissionNever,
	}
	results, wait, err = mcp.resolveSnapshots(context.Background(), 7, academic.ResolveContextRequest{
		Datasets: []academic.DatasetType{academic.DatasetGrades}, Freshness: academic.FreshnessPreferRecent, Reason: "grade_summary",
	})
	require.NoError(t, err)
	require.Nil(t, wait)
	require.Equal(t, academic.DataStatusPermissionRequired, results[academic.DatasetGrades].Status)
	require.Zero(t, reader.generationCalls)
	require.Zero(t, reader.lookupCalls)
}

func TestPermissionDecisionIsScopedToRunAndExpiry(t *testing.T) {
	db := newRuntimeTestDB(t)
	now := time.Date(2026, 7, 26, 9, 0, 0, 0, time.UTC)
	mcp := &campusMCP{db: db, permissions: fixedPersonalDataPermissionReader{}, now: func() time.Time { return now }}
	require.NoError(t, db.Create(&models.AIRunConsent{
		RunID: "run-allowed", UserID: 7, Scope: models.AIUserPermissionPersonalDataAccess, Granted: true, ExpiresAt: now.Add(time.Minute),
	}).Error)
	require.NoError(t, db.Create(&models.AIRunConsent{
		RunID: "run-denied", UserID: 7, Scope: models.AIUserPermissionPersonalDataAccess, Granted: false, ExpiresAt: now.Add(time.Minute),
	}).Error)
	require.NoError(t, db.Create(&models.AIRunConsent{
		RunID: "run-expired", UserID: 7, Scope: models.AIUserPermissionPersonalDataAccess, Granted: true, ExpiresAt: now.Add(-time.Second),
	}).Error)

	decision, err := mcp.permissionDecision(withToolCallContext(context.Background(), "run-allowed", "call-1", 7, "tool"), 7, models.AIUserPermissionPersonalDataAccess)
	require.NoError(t, err)
	require.Equal(t, PermissionDecisionAllow, decision)
	decision, err = mcp.permissionDecision(withToolCallContext(context.Background(), "run-other", "call-2", 7, "tool"), 7, models.AIUserPermissionPersonalDataAccess)
	require.NoError(t, err)
	require.Equal(t, PermissionDecisionAsk, decision)
	decision, err = mcp.permissionDecision(withToolCallContext(context.Background(), "run-denied", "call-3", 7, "tool"), 7, models.AIUserPermissionPersonalDataAccess)
	require.NoError(t, err)
	require.Equal(t, PermissionDecisionDeny, decision)
	decision, err = mcp.permissionDecision(withToolCallContext(context.Background(), "run-expired", "call-4", 7, "tool"), 7, models.AIUserPermissionPersonalDataAccess)
	require.NoError(t, err)
	require.Equal(t, PermissionDecisionAsk, decision)
}
