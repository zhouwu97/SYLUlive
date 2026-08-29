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
	require.Equal(t, "observed_risk", data["risk_level"])
	require.Contains(t, data["risks"], "发现 1 门未通过课程（大学物理B2）")
	require.Equal(t, 3, data["available_dataset_count"])
	require.Equal(t, []string{"erke"}, data["optional_missing"])
	require.Equal(t, "update_erke", data["optional_actions"].([]map[string]interface{})[0]["id"])
}

func TestCampusMCPRiskAnalysisSchedulesOneAcademicBundle(t *testing.T) {
	reader := academicAnalysisSnapshotReader{results: map[academic.DatasetType]academic.ContextResult{
		academic.DatasetGrades: {
			Data:   json.RawMessage(`{"grades":[{"course_name":"大学物理B2","credits":3,"fraction":45}]}`),
			Status: academic.DataStatusAvailable, Source: academic.DataSourceServerSnapshot,
		},
	}}
	var scheduled DeviceJobRequest
	deviceJobs := 0
	tools := NewCampusMCPTools(newRuntimeTestDB(t), reader, nil,
		WithCampusPersonalDataPermissionReader(AllowAllPermissionReader{}),
		WithCampusDeviceJobScheduler(DeviceJobSchedulerFunc(func(_ context.Context, request DeviceJobRequest) (DeviceJobReference, error) {
			deviceJobs++
			scheduled = request
			return DeviceJobReference{ID: "device-job"}, nil
		})),
	)

	value, err := campusToolByName(t, tools, "academic.get_risk_analysis").Execute(
		withToolCallContext(context.Background(), "run-risk", "call-risk", 7, "academic.get_risk_analysis"),
		7,
		json.RawMessage(`{}`),
	)
	require.NoError(t, err)
	wait, ok := value.(ToolWait)
	require.True(t, ok)
	require.Equal(t, models.AIRunStateWaitingDevice, wait.State)
	require.Equal(t, "device-job", wait.ResumeKey)
	require.Equal(t, []string{"grades", "academic_situation", "credit_requirements"}, scheduled.RequiredDataTypes)
	require.Equal(t, "device.academic.ensure_fresh_bundle", scheduled.ToolName)
	require.JSONEq(t, `{"max_age_seconds":{"grades":300,"academic_situation":21600,"credit_requirements":86400}}`, string(scheduled.Arguments))
	require.Equal(t, 1, deviceJobs, "risk analysis must create one bundle wait")
}

func TestCampusMCPRiskAnalysisPartialCoreDataSchedulesAcademicBundle(t *testing.T) {
	reader := academicAnalysisSnapshotReader{results: map[academic.DatasetType]academic.ContextResult{
		academic.DatasetGrades: {
			Data: json.RawMessage(`{"grades":[{"course_name":"高等数学","fraction":92}]}`), Status: academic.DataStatusPartial,
			IsPartial: true, Source: academic.DataSourceServerSnapshot,
		},
		academic.DatasetCreditRequirements: {
			Data: json.RawMessage(`{"earned_credits":30,"required_credits":30}`), Status: academic.DataStatusAvailable, Source: academic.DataSourceServerSnapshot,
		},
		academic.DatasetAcademicSituation: {
			Data: json.RawMessage(`{"earned_credits":30,"required_credits":30}`), Status: academic.DataStatusAvailable, Source: academic.DataSourceServerSnapshot,
		},
	}}
	deviceJobs := 0
	tools := NewCampusMCPTools(newRuntimeTestDB(t), reader, nil,
		WithCampusPersonalDataPermissionReader(AllowAllPermissionReader{}),
		WithCampusDeviceJobScheduler(DeviceJobSchedulerFunc(func(context.Context, DeviceJobRequest) (DeviceJobReference, error) {
			deviceJobs++
			return DeviceJobReference{ID: "device-job"}, nil
		})),
	)

	value, err := campusToolByName(t, tools, "academic.get_risk_analysis").Execute(
		withToolCallContext(context.Background(), "run-partial", "call-partial", 7, "academic.get_risk_analysis"),
		7,
		json.RawMessage(`{}`),
	)
	require.NoError(t, err)
	_, waiting := value.(ToolWait)
	require.True(t, waiting)
	require.Equal(t, 1, deviceJobs)
}

func TestCampusMCPRiskAnalysisFreshCoreDataSchedulesOnlyErkeRefresh(t *testing.T) {
	now := time.Now()
	reader := academicAnalysisSnapshotReader{results: map[academic.DatasetType]academic.ContextResult{
		academic.DatasetGrades: {
			Data: json.RawMessage(`{"grades":[{"course_name":"高等数学","fraction":92}]}`), Status: academic.DataStatusAvailable, Source: academic.DataSourceServerSnapshot,
		},
		academic.DatasetCreditRequirements: {
			Data: json.RawMessage(`{"earned_credits":30,"required_credits":30}`), Status: academic.DataStatusAvailable, Source: academic.DataSourceServerSnapshot,
		},
		academic.DatasetAcademicSituation: {
			Data: json.RawMessage(`{"earned_credits":30,"required_credits":30}`), Status: academic.DataStatusAvailable, Source: academic.DataSourceServerSnapshot,
		},
	}}
	var scheduled DeviceJobRequest
	deviceJobs := 0
	scheduler := DeviceJobSchedulerFunc(func(_ context.Context, request DeviceJobRequest) (DeviceJobReference, error) {
		deviceJobs++
		scheduled = request
		return DeviceJobReference{ID: "erke-job"}, nil
	})
	tools := NewCampusMCPTools(newRuntimeTestDB(t), reader, nil,
		WithCampusPersonalDataPermissionReader(AllowAllPermissionReader{}),
		WithCampusDeviceJobScheduler(scheduler),
	)

	value, err := campusToolByName(t, tools, "academic.get_risk_analysis").Execute(
		withToolCallContext(context.Background(), "run-fresh", "call-fresh", 7, "academic.get_risk_analysis"),
		7,
		json.RawMessage(`{}`),
	)
	require.NoError(t, err)
	_, ok := value.(ToolWait)
	require.True(t, ok, "核心数据新鲜但二课缺失时应为二课排队一次")
	require.Equal(t, "device.erke.ensure_fresh_overview", scheduled.ToolName)
	require.Equal(t, 1, deviceJobs, "不得为已新鲜的核心数据重建 bundle")
	require.JSONEq(t, `{"max_age_seconds":1800,"allow_upload":true}`, string(scheduled.Arguments))

	// 二课已可用时不排任何设备任务。
	erkeReader := fixedPersonalSnapshotReader{lookup: academic.SnapshotLookup{
		Found: true,
		Result: academic.ContextResult{
			Data: json.RawMessage(`{"graduation":{"earned_total":42.5,"required_total":60}}`),
			Status: academic.DataStatusAvailable, Source: academic.DataSourceUserUploadedSnapshot,
			FetchedAt: &now,
		},
	}}
	idleTools := NewCampusMCPTools(newRuntimeTestDB(t), reader, erkeReader,
		WithCampusPersonalDataPermissionReader(AllowAllPermissionReader{}),
		WithCampusDeviceJobScheduler(DeviceJobSchedulerFunc(func(context.Context, DeviceJobRequest) (DeviceJobReference, error) {
			deviceJobs++
			return DeviceJobReference{ID: "unexpected"}, nil
		})),
	)
	value, err = campusToolByName(t, idleTools, "academic.get_risk_analysis").Execute(
		withToolCallContext(context.Background(), "run-fresh-idle", "call-fresh-idle", 7, "academic.get_risk_analysis"),
		7,
		json.RawMessage(`{}`),
	)
	require.NoError(t, err)
	_, waiting := value.(ToolWait)
	require.False(t, waiting)
	require.Equal(t, 1, deviceJobs, "二课可用时不得新增设备任务")
}

func TestCampusMCPRiskAnalysisErkePermissionNeverSkipsRefresh(t *testing.T) {
	reader := academicAnalysisSnapshotReader{results: map[academic.DatasetType]academic.ContextResult{
		academic.DatasetGrades: {
			Data: json.RawMessage(`{"grades":[{"course_name":"高等数学","fraction":92}]}`), Status: academic.DataStatusAvailable, Source: academic.DataSourceServerSnapshot,
		},
		academic.DatasetCreditRequirements: {
			Data: json.RawMessage(`{"earned_credits":30,"required_credits":30}`), Status: academic.DataStatusAvailable, Source: academic.DataSourceServerSnapshot,
		},
		academic.DatasetAcademicSituation: {
			Data: json.RawMessage(`{"earned_credits":30,"required_credits":30}`), Status: academic.DataStatusAvailable, Source: academic.DataSourceServerSnapshot,
		},
	}}
	deviceJobs := 0
	tools := NewCampusMCPTools(newRuntimeTestDB(t), reader, nil,
		WithCampusPersonalDataPermissionReader(fixedPersonalDataPermissionReader{
			models.AIUserPermissionPersonalDataAccess:    models.AIUserPermissionAlways,
			models.AIUserPermissionAcademicCloudStorage:  models.AIUserPermissionAlways,
			models.AIUserPermissionDeviceCacheAccess:     models.AIUserPermissionAlways,
			models.AIUserPermissionRemoteEduRefresh:      models.AIUserPermissionAlways,
			models.AIUserPermissionExternalModelAnalysis: models.AIUserPermissionAlways,
			models.AIUserPermissionErkeSnapshotUpload:    models.AIUserPermissionNever,
		}),
		WithCampusDeviceJobScheduler(DeviceJobSchedulerFunc(func(context.Context, DeviceJobRequest) (DeviceJobReference, error) {
			deviceJobs++
			return DeviceJobReference{ID: "unexpected"}, nil
		})),
	)

	value, err := campusToolByName(t, tools, "academic.get_risk_analysis").Execute(
		withToolCallContext(context.Background(), "run-never", "call-never", 7, "academic.get_risk_analysis"),
		7,
		json.RawMessage(`{}`),
	)
	require.NoError(t, err)
	_, waiting := value.(ToolWait)
	require.False(t, waiting, "用户关闭二课上传授权时不得排队刷新")
	require.Equal(t, 0, deviceJobs)
}

func TestCampusMCPRiskAnalysisExpiredBundleExplainsTimeout(t *testing.T) {
	fetched := time.Now().Add(-3 * time.Hour)
	reader := academicAnalysisSnapshotReader{results: map[academic.DatasetType]academic.ContextResult{
		academic.DatasetGrades: {
			Data: json.RawMessage(`{"grades":[{"course_name":"高等数学","fraction":92}]}`),
			Status: academic.DataStatusStale, IsStale: true,
			Source: academic.DataSourceServerSnapshot, FetchedAt: &fetched,
			Warnings: []string{"该学业快照已过期"},
		},
		academic.DatasetCreditRequirements: {
			Data: json.RawMessage(`{"earned_credits":30,"required_credits":30}`),
			Status: academic.DataStatusStale, IsStale: true,
			Source: academic.DataSourceServerSnapshot, FetchedAt: &fetched,
		},
		academic.DatasetAcademicSituation: {
			Data: json.RawMessage(`{"earned_credits":30,"required_credits":30}`),
			Status: academic.DataStatusStale, IsStale: true,
			Source: academic.DataSourceServerSnapshot, FetchedAt: &fetched,
		},
	}}
	deviceJobs := 0
	tools := NewCampusMCPTools(newRuntimeTestDB(t), reader, nil,
		WithCampusPersonalDataPermissionReader(AllowAllPermissionReader{}),
		WithCampusDeviceJobScheduler(DeviceJobSchedulerFunc(func(context.Context, DeviceJobRequest) (DeviceJobReference, error) {
			deviceJobs++
			return DeviceJobReference{ID: "unexpected"}, nil
		})),
	)
	ctx := withToolCallContext(context.Background(), "run-expired", "call-expired", 7, "academic.get_risk_analysis")
	ctx = withDeviceJobResumeContext(ctx, deviceJobResumeContext{
		JobID: "device-job", ToolName: "device.academic.ensure_fresh_bundle", Dataset: "academic_bundle",
		Status: models.DeviceToolJobExpired,
	})

	value, err := campusToolByName(t, tools, "academic.get_risk_analysis").Execute(ctx, 7, json.RawMessage(`{}`))
	require.NoError(t, err)
	require.Equal(t, 0, deviceJobs, "bundle 超时后桥接不可靠，不得追加二课等待")
	envelope := value.(CampusToolResult)
	require.Contains(t, envelope.Warnings, "已尝试通过手机刷新学业数据但任务超时；以下分析仅基于最近一次同步的数据")
	require.Contains(t, envelope.Warnings, "成绩数据为3小时前同步，已超出本次实时分析要求")
	require.NotContains(t, envelope.Warnings, "该学业快照已过期")
	refresh := envelope.Data.(map[string]interface{})["refresh"].(map[string]interface{})
	require.Equal(t, "device_job_failed", refresh["status"])
}

func TestCampusMCPRiskAnalysisResumedPartialBundleSchedulesOnlyErke(t *testing.T) {
	reader := academicAnalysisSnapshotReader{}
	var scheduled DeviceJobRequest
	deviceJobs := 0
	tools := NewCampusMCPTools(newRuntimeTestDB(t), reader, nil,
		WithCampusPersonalDataPermissionReader(AllowAllPermissionReader{}),
		WithCampusDeviceJobScheduler(DeviceJobSchedulerFunc(func(_ context.Context, request DeviceJobRequest) (DeviceJobReference, error) {
			deviceJobs++
			scheduled = request
			return DeviceJobReference{ID: "erke-job"}, nil
		})),
	)
	resumeResult := json.RawMessage(`{
		"data": {
			"grades":{"data":{"grades":[]},"source":"remote_edu_fetch","is_partial":true},
			"academic_situation":{"data":{"earned_credits":30,"required_credits":30},"source":"remote_edu_fetch"},
			"credit_requirements":{"data":{"earned_credits":30,"required_credits":30},"source":"remote_edu_fetch"}
		}
	}`)
	ctx := withToolCallContext(context.Background(), "run-resume", "call-resume", 7, "academic.get_risk_analysis")
	ctx = withDeviceJobResumeContext(ctx, deviceJobResumeContext{
		JobID: "device-job", ToolName: "device.academic.ensure_fresh_bundle", Dataset: "academic_bundle",
		Status: models.DeviceToolJobCompleted, Result: resumeResult,
	})

	value, err := campusToolByName(t, tools, "academic.get_risk_analysis").Execute(ctx, 7, json.RawMessage(`{}`))
	require.NoError(t, err)
	_, waiting := value.(ToolWait)
	require.True(t, waiting, "bundle 完成后应为缺失的二课排队一次")
	require.Equal(t, 1, deviceJobs, "partial 设备结果不得触发第二个 bundle")
	require.Equal(t, "device.erke.ensure_fresh_overview", scheduled.ToolName)

	// 二课任务终态后必须直接完成，不得再排队任何设备任务（防环）。
	finalCtx := withDeviceJobResumeContext(ctx, deviceJobResumeContext{
		JobID: "erke-job", ToolName: "device.erke.ensure_fresh_overview", Dataset: "erke",
		Status: models.DeviceToolJobExpired,
	})
	value, err = campusToolByName(t, tools, "academic.get_risk_analysis").Execute(finalCtx, 7, json.RawMessage(`{}`))
	require.NoError(t, err)
	_, waiting = value.(ToolWait)
	require.False(t, waiting, "二课刷新失败后不得再次排队")
	require.Equal(t, 1, deviceJobs)
}

func TestCampusMCPRiskAnalysisRefreshIncompleteKeepsExistingDataWithoutLoop(t *testing.T) {
	reader := academicAnalysisSnapshotReader{results: map[academic.DatasetType]academic.ContextResult{
		academic.DatasetGrades: {
			Data: json.RawMessage(`{"grades":[{"course_name":"高等数学","fraction":92}]}`), Status: academic.DataStatusPartial,
			IsPartial: true, Source: academic.DataSourceServerSnapshot,
		},
		academic.DatasetCreditRequirements: {
			Data: json.RawMessage(`{"earned_credits":30,"required_credits":30}`), Status: academic.DataStatusAvailable, Source: academic.DataSourceServerSnapshot,
		},
		academic.DatasetAcademicSituation: {
			Data: json.RawMessage(`{"earned_credits":30,"required_credits":30}`), Status: academic.DataStatusAvailable, Source: academic.DataSourceServerSnapshot,
		},
	}}
	deviceJobs := 0
	tools := NewCampusMCPTools(newRuntimeTestDB(t), reader, nil,
		WithCampusPersonalDataPermissionReader(AllowAllPermissionReader{}),
		WithCampusDeviceJobScheduler(DeviceJobSchedulerFunc(func(context.Context, DeviceJobRequest) (DeviceJobReference, error) {
			deviceJobs++
			return DeviceJobReference{ID: "unexpected"}, nil
		})),
	)
	ctx := withToolCallContext(context.Background(), "run-failed", "call-failed", 7, "academic.get_risk_analysis")
	ctx = withDeviceJobResumeContext(ctx, deviceJobResumeContext{
		JobID: "device-job", ToolName: "device.academic.ensure_fresh_bundle", Dataset: "academic_bundle",
		Status: models.DeviceToolJobFailed, ErrorCode: "refresh_incomplete",
	})

	value, err := campusToolByName(t, tools, "academic.get_risk_analysis").Execute(ctx, 7, json.RawMessage(`{}`))
	require.NoError(t, err)
	require.Equal(t, 0, deviceJobs)
	data := value.(CampusToolResult).Data.(map[string]interface{})
	require.Equal(t, 3, data["core_available_dataset_count"])
	refresh := data["refresh"].(map[string]interface{})
	require.Equal(t, "refresh_incomplete", refresh["status"])
}

func TestAcademicRiskOptionalActionsOnlyExposeWhitelistedErkeEntry(t *testing.T) {
	actions := academicRiskOptionalActions("academic.get_risk_analysis", json.RawMessage(`{
		"data":{"optional_actions":[{"id":"update_erke"},{"id":"unexpected"}]}
	}`))
	require.Equal(t, []string{"update_erke"}, actions)
	require.Nil(t, academicRiskOptionalActions("academic.get_grade_summary", json.RawMessage(`{
		"data":{"optional_actions":[{"id":"update_erke"}]}
	}`)))
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
