package ai

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/stretchr/testify/require"
	"gorm.io/datatypes"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/academic"
	"shenliyuan/internal/ai/mcpclient"
	"shenliyuan/internal/models"
)

type fixedHy3AcademicSnapshotReader struct {
	generation uint
	lookups    map[academic.DatasetType]academic.SnapshotLookup
}

func (reader fixedHy3AcademicSnapshotReader) CurrentCredentialGeneration(context.Context, uint) (uint, error) {
	return reader.generation, nil
}

func (reader fixedHy3AcademicSnapshotReader) LookupLatest(_ context.Context, _ uint, dataset academic.DatasetType, _ uint) (academic.SnapshotLookup, error) {
	return reader.lookups[dataset], nil
}

type fixedHy3PersonalSnapshotReader struct {
	lookup academic.SnapshotLookup
}

func (reader fixedHy3PersonalSnapshotReader) LookupErke(context.Context, uint) (academic.SnapshotLookup, error) {
	return reader.lookup, nil
}

type recordedMCPCall struct {
	name      string
	arguments map[string]interface{}
}

type recordingExternalMCPClient struct {
	response json.RawMessage
	err      error
	calls    []recordedMCPCall
}

func (client *recordingExternalMCPClient) Connect(context.Context) error { return nil }

func (client *recordingExternalMCPClient) ListTools(context.Context) ([]mcpclient.RemoteToolDefinition, error) {
	return nil, nil
}

func (client *recordingExternalMCPClient) CallTool(_ context.Context, name string, arguments map[string]interface{}) (json.RawMessage, error) {
	client.calls = append(client.calls, recordedMCPCall{name: name, arguments: arguments})
	if client.err != nil {
		return nil, client.err
	}
	return append(json.RawMessage(nil), client.response...), nil
}

func (client *recordingExternalMCPClient) Healthy() bool { return client.err == nil }

func (client *recordingExternalMCPClient) Close() error { return nil }

func newHy3DecisionTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	dsn := fmt.Sprintf("file:hy3-decision-%s?mode=memory&cache=shared", uuid.NewString())
	db, err := gorm.Open(sqlite.Open(dsn), &gorm.Config{})
	require.NoError(t, err)
	sqlDB, err := db.DB()
	require.NoError(t, err)
	sqlDB.SetMaxOpenConns(1)
	require.NoError(t, db.AutoMigrate(
		&models.AIToolCall{},
		&models.AIRunConsent{},
		&models.CampusCalendar{},
		&models.ClassPeriodProfile{},
	))
	return db
}

func TestHy3ExternalPermissionAskWaitsBeforeSnapshotRead(t *testing.T) {
	db := newHy3DecisionTestDB(t)
	reader := &countingAcademicSnapshotReader{}
	remote := &recordingExternalMCPClient{response: hy3RemoteResponse(hy3AcademicNarrative(), hy3AcademicFindings())}
	decision := &hy3DecisionMCP{
		db: db, remote: remote,
		campus: &campusMCP{
			db: db, snapshots: reader, now: time.Now,
			permissions: fixedPersonalDataPermissionReader{
				models.AIUserPermissionPersonalDataAccess:    models.AIUserPermissionAlways,
				models.AIUserPermissionAcademicCloudStorage:  models.AIUserPermissionAlways,
				models.AIUserPermissionExternalModelAnalysis: models.AIUserPermissionAsk,
			},
		},
	}
	value, err := decision.analyzeAcademic(
		withToolCallContext(context.Background(), "run-external-ask", "call-external-ask", 7, "hy3_decision.analyze_academic"),
		7, json.RawMessage(`{}`),
	)
	require.NoError(t, err)
	wait, ok := value.(ToolWait)
	require.True(t, ok)
	require.Equal(t, models.AIUserPermissionExternalModelAnalysis, wait.ConsentScope)
	require.Zero(t, reader.generationCalls)
	require.Zero(t, reader.lookupCalls)
	require.Empty(t, remote.calls)
}

func TestHy3ExternalPermissionNeverBlocksAllRemoteCalls(t *testing.T) {
	tests := []struct {
		name      string
		arguments json.RawMessage
		execute   func(*hy3DecisionMCP, context.Context, uint, json.RawMessage) (interface{}, error)
	}{
		{name: "competition", arguments: json.RawMessage(`{"event_ids":[1,2]}`), execute: (*hy3DecisionMCP).compareCompetitions},
		{name: "academic", arguments: json.RawMessage(`{}`), execute: (*hy3DecisionMCP).analyzeAcademic},
		{name: "week_plan", arguments: json.RawMessage(`{"week":8,"goals":[]}`), execute: (*hy3DecisionMCP).planStudentWeek},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			db := newHy3DecisionTestDB(t)
			reader := &countingAcademicSnapshotReader{}
			remote := &recordingExternalMCPClient{response: json.RawMessage(`{"status":"ok"}`)}
			decision := &hy3DecisionMCP{
				db: db, remote: remote,
				campus: &campusMCP{
					db: db, snapshots: reader, now: time.Now,
					permissions: fixedPersonalDataPermissionReader{
						models.AIUserPermissionPersonalDataAccess:    models.AIUserPermissionAlways,
						models.AIUserPermissionAcademicCloudStorage:  models.AIUserPermissionAlways,
						models.AIUserPermissionExternalModelAnalysis: models.AIUserPermissionNever,
					},
				},
			}
			value, err := test.execute(decision, context.Background(), 7, test.arguments)
			require.NoError(t, err)
			result, ok := value.(map[string]interface{})
			require.True(t, ok)
			require.Equal(t, "unavailable", result["status"])
			require.Empty(t, remote.calls)
			require.Zero(t, reader.generationCalls)
			require.Zero(t, reader.lookupCalls)
		})
	}
}

func availableHy3Result(raw string) academic.ContextResult {
	return academic.ContextResult{
		Data:     json.RawMessage(raw),
		Status:   academic.DataStatusAvailable,
		Source:   academic.DataSourceServerSnapshot,
		Warnings: make([]string, 0),
		Evidence: make([]academic.Evidence, 0),
	}
}

func hy3RemoteResponse(result, findings map[string]interface{}) json.RawMessage {
	payload, err := json.Marshal(map[string]interface{}{
		"status":                 "ok",
		"result":                 result,
		"deterministic_findings": findings,
		"warnings":               []string{},
	})
	if err != nil {
		panic(err)
	}
	return payload
}

func hy3AcademicNarrative() map[string]interface{} {
	return map[string]interface{}{
		"risk_summary":     "优先处理未通过课程。",
		"priority_actions": []string{"确认补修安排"},
		"items_to_confirm": []string{"确认最终成绩"},
	}
}

func hy3AcademicFindings() map[string]interface{} {
	return map[string]interface{}{
		"failed_course_count":         1,
		"failed_required_credits":     4,
		"earned_credits":              72,
		"credit_gap":                  88,
		"erke_gap":                    12,
		"unknown_grade_course_count":  0,
		"missing_credit_course_count": 0,
		"data_completeness_percent":   100,
		"failed_courses":              []string{"高等数学"},
	}
}

func hy3PlanNarrative() map[string]interface{} {
	return map[string]interface{}{
		"weekly_strategy": "优先完成高优先级目标。",
		"priority_order":  []string{"高优先级目标"},
		"notes":           []string{"保持课程与睡眠边界。"},
	}
}

func TestHy3AcademicAdapterRedactsPersonalDataAndAuditArguments(t *testing.T) {
	db := newHy3DecisionTestDB(t)
	remote := &recordingExternalMCPClient{response: hy3RemoteResponse(
		hy3AcademicNarrative(),
		hy3AcademicFindings(),
	)}
	snapshots := fixedHy3AcademicSnapshotReader{
		generation: 1,
		lookups: map[academic.DatasetType]academic.SnapshotLookup{
			academic.DatasetGrades: {Found: true, Result: availableHy3Result(`{
				"user_id":7,"student_id":"20260001","name":"张三","cookie":"private-cookie","token":"private-token","password":"private-password",
				"grades":[{"course_name":"高等数学","credit":4,"score":58,"student_id":"20260001","name":"张三"}]
			}`)},
			academic.DatasetCreditRequirements: {Found: true, Result: availableHy3Result(`{
				"user_id":7,"earned_credits":72,"required_credits":160,"jwt":"private-jwt"
			}`)},
			academic.DatasetAcademicSituation: {Found: false},
			academic.DatasetErke:              {Found: true, Result: availableHy3Result(`{"earned_total":18,"required_total":30,"student_id":"20260001"}`)},
		},
	}
	tools := NewHy3DecisionTools(db, snapshots, nil, remote)
	registry, err := NewToolRegistry(db, tools...)
	require.NoError(t, err)

	_, duplicate, err := registry.Execute(
		context.Background(), "hy3-call-1", "hy3-run-1", 7,
		"hy3_decision.analyze_academic", json.RawMessage(`{"question":"我最需要补什么"}`),
	)
	require.NoError(t, err)
	require.False(t, duplicate)
	require.Len(t, remote.calls, 1)
	require.Equal(t, "analyze_academic_snapshot", remote.calls[0].name)
	assertNoSensitiveRemoteFields(t, remote.calls[0].arguments)

	var persisted models.AIToolCall
	require.NoError(t, db.First(&persisted, "call_id = ?", "hy3-call-1").Error)
	require.JSONEq(t, `{"question":"我最需要补什么"}`, string(persisted.ArgumentsJSON))
	require.NotContains(t, string(persisted.ArgumentsJSON), "高等数学")
	require.NotContains(t, string(persisted.ArgumentsJSON), "20260001")
}

func TestHy3AdapterRejectsUnexpectedPersonalPayloadBeforeAudit(t *testing.T) {
	db := newHy3DecisionTestDB(t)
	remote := &recordingExternalMCPClient{response: hy3RemoteResponse(hy3AcademicNarrative(), hy3AcademicFindings())}
	tools := NewHy3DecisionTools(db, fixedHy3AcademicSnapshotReader{}, nil, remote)
	registry, err := NewToolRegistry(db, tools...)
	require.NoError(t, err)

	_, _, err = registry.Execute(
		context.Background(), "hy3-call-rejected", "hy3-run-rejected", 7,
		"hy3_decision.analyze_academic", json.RawMessage(`{
			"question":"我最需要补什么",
			"snapshot":{"student_id":"20260001","grades":[{"course_name":"高等数学","score":58}]}
		}`),
	)
	require.EqualError(t, err, "invalid_tool_call")
	require.Empty(t, remote.calls)

	var count int64
	require.NoError(t, db.Model(&models.AIToolCall{}).Where("call_id = ?", "hy3-call-rejected").Count(&count).Error)
	require.Zero(t, count)
}

func TestHy3DecisionRejectsSecondExternalCallInSameRun(t *testing.T) {
	db := newHy3DecisionTestDB(t)
	require.NoError(t, db.Create(&models.AIToolCall{
		CallID:        "hy3-call-first",
		RunID:         "hy3-run-shared",
		UserID:        7,
		ToolName:      "hy3_decision.analyze_academic",
		ToolVersion:   hy3DecisionToolVersion,
		ArgumentsJSON: datatypes.JSON([]byte(`{}`)),
		ArgumentsHash: "arguments-hash",
		Status:        "completed",
		ExpiresAt:     time.Now().Add(time.Minute),
	}).Error)

	decision := &hy3DecisionMCP{db: db}
	result := decision.reserveExternalCall(withToolCallContext(
		context.Background(), "hy3-run-shared", "hy3-call-second", 7, "hy3_decision.plan_student_week",
	))
	require.NotNil(t, result)
	require.Equal(t, "unavailable", result["status"])
	require.Equal(t, mcpclient.ErrorConstraint, result["error_code"])
}

func TestHy3PlanRefusesMissingCalendarOrPeriodMapping(t *testing.T) {
	tests := []struct {
		name         string
		seedCalendar bool
	}{
		{name: "缺少已发布校历"},
		{name: "缺少已发布节次映射", seedCalendar: true},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			db := newHy3DecisionTestDB(t)
			if test.seedCalendar {
				seedHy3Calendar(t, db)
			}
			remote := &recordingExternalMCPClient{response: hy3RemoteResponse(map[string]interface{}{}, map[string]interface{}{})}
			decision := newHy3PlanDecision(db, remote, `{"courses":[]}`)

			value, err := decision.planStudentWeek(context.Background(), 7, json.RawMessage(`{"week":8,"goals":[]}`))
			require.NoError(t, err)
			result := value.(map[string]interface{})
			require.Equal(t, "unavailable", result["status"])
			require.Equal(t, mcpclient.ErrorConstraint, result["error_code"])
			require.Empty(t, remote.calls)
		})
	}
}

func TestHy3PlanRejectsRemotePlanThatConflictsWithCourse(t *testing.T) {
	db := newHy3DecisionTestDB(t)
	seedHy3Calendar(t, db)
	seedHy3ClassPeriods(t, db)
	remote := &recordingExternalMCPClient{response: hy3RemoteResponse(
		hy3PlanNarrative(),
		map[string]interface{}{"plan": []map[string]interface{}{
			{
				"goal":     "准备蓝桥杯",
				"priority": "high",
				"weekday":  1,
				"date":     "2026-04-20",
				"start":    "08:30",
				"end":      "09:00",
				"minutes":  30,
			},
		}, "private_plan": "该字段不能返回给模型"},
	)}
	decision := newHy3PlanDecision(db, remote, `{
		"courses":[{"course_name":"高等数学","week_day":1,"time":1,"end_time":1,"weeks":[8]}]
	}`)

	value, err := decision.planStudentWeek(context.Background(), 7, json.RawMessage(`{"week":8,"goals":[{"name":"准备蓝桥杯","weekly_minutes":30,"priority":"high"}]}`))
	require.NoError(t, err)
	result := value.(map[string]interface{})
	require.Equal(t, "unavailable", result["status"])
	require.Equal(t, mcpclient.ErrorConstraint, result["error_code"])
	require.Contains(t, result["issues"], "plan_conflicts_fixed_event")
	encoded, err := json.Marshal(result)
	require.NoError(t, err)
	require.NotContains(t, string(encoded), "private_plan")
	require.Len(t, remote.calls, 1)
}

func TestHy3PlanReturnsOnlyLocallyRebuiltFindings(t *testing.T) {
	db := newHy3DecisionTestDB(t)
	seedHy3Calendar(t, db)
	seedHy3ClassPeriods(t, db)
	remote := &recordingExternalMCPClient{response: hy3RemoteResponse(
		hy3PlanNarrative(),
		map[string]interface{}{
			"plan": []map[string]interface{}{
				{
					"goal":     "准备蓝桥杯",
					"priority": "high",
					"weekday":  1,
					"date":     "2026-04-20",
					"start":    "07:00",
					"end":      "09:00",
					"minutes":  120,
				},
			},
			"private_plan":            "该字段不能返回给模型",
			"total_scheduled_minutes": 999999,
		},
	)}
	decision := newHy3PlanDecision(db, remote, `{
		"courses":[{"course_name":"高级神经网络课程","week_day":2,"time":1,"end_time":1,"weeks":[8]}]
	}`)

	value, err := decision.planStudentWeek(context.Background(), 7, json.RawMessage(`{"week":8,"goals":[{"name":"准备蓝桥杯","weekly_minutes":120,"priority":"high"}]}`))
	require.NoError(t, err)
	result := value.(map[string]interface{})
	require.Equal(t, "ok", result["status"])
	findings := result["deterministic_findings"].(map[string]interface{})
	require.NotContains(t, findings, "private_plan")
	require.Equal(t, 120, findings["total_scheduled_minutes"])
	encoded, marshalErr := json.Marshal(result)
	require.NoError(t, marshalErr)
	require.NotContains(t, string(encoded), "999999")
	require.NotContains(t, string(encoded), "private_plan")
	require.Len(t, remote.calls, 1)
	remoteArguments, marshalErr := json.Marshal(remote.calls[0].arguments)
	require.NoError(t, marshalErr)
	require.NotContains(t, string(remoteArguments), "高级神经网络课程")
	require.Contains(t, string(remoteArguments), `"title":"课程"`)
}

func TestHy3NarrativeContractRejectsUnexpectedFields(t *testing.T) {
	result := hy3PlanNarrative()
	result["private_plan"] = "未约定字段"
	_, err := sanitizeHy3NarrativeResult("plan_student_week", result)
	require.Error(t, err)
}

func TestHy3ValidatedToolsOnlyIncludeCompatibleRemoteDefinitions(t *testing.T) {
	remote := &recordingExternalMCPClient{}
	tools := NewValidatedHy3DecisionTools(nil, nil, nil, remote, []mcpclient.RemoteToolDefinition{
		{Name: "plan_student_week"},
	})
	require.Len(t, tools, 1)
	require.Equal(t, "hy3_decision.plan_student_week", tools[0].Name())
}

func TestSchoolRecognitionRequiresExplicitPositiveStatus(t *testing.T) {
	require.True(t, schoolRecognitionConfirmed("recognized"))
	require.True(t, schoolRecognitionConfirmed("已认定"))
	require.False(t, schoolRecognitionConfirmed("未认定"))
	require.False(t, schoolRecognitionConfirmed("pending"))
}

func TestResolveWeekStartComparesCalendarDateInsteadOfInstant(t *testing.T) {
	db := newHy3DecisionTestDB(t)
	seedHy3Calendar(t, db)
	decision := &hy3DecisionMCP{db: db}

	previousLocal := time.Local
	time.Local = time.UTC
	defer func() { time.Local = previousLocal }()

	start, _, err := decision.resolveWeekStart(context.Background(), json.RawMessage(`{"week_start":"2026-04-20"}`), 8)
	require.NoError(t, err)
	require.Equal(t, "2026-04-20", start.Format("2006-01-02"))
	require.Equal(t, "Asia/Shanghai", start.Location().String())
}

func newHy3PlanDecision(db *gorm.DB, remote mcpclient.ExternalMCPClient, schedule string) *hy3DecisionMCP {
	return &hy3DecisionMCP{
		db:     db,
		remote: remote,
		campus: &campusMCP{
			db: db,
			snapshots: fixedHy3AcademicSnapshotReader{
				generation: 1,
				lookups: map[academic.DatasetType]academic.SnapshotLookup{
					academic.DatasetSchedule: {Found: true, Result: availableHy3Result(schedule)},
				},
			},
			now: time.Now,
		},
	}
}

func seedHy3Calendar(t *testing.T, db *gorm.DB) {
	t.Helper()
	now := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	require.NoError(t, db.Create(&models.CampusCalendar{
		AcademicYear: "2025-2026",
		Version:      1,
		Status:       "published",
		Data: datatypes.JSON([]byte(`{
			"academic_year":"2025-2026",
			"timezone":"Asia/Shanghai",
			"semesters":[{"teaching_weeks":[{
				"week":8,"start_date":"2026-04-20","end_date":"2026-04-26"
			}]}]
		}`)),
		PublishedAt: &now,
	}).Error)
}

func seedHy3ClassPeriods(t *testing.T, db *gorm.DB) {
	t.Helper()
	publishedAt := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	require.NoError(t, db.Create(&models.ClassPeriodProfile{
		AcademicYear:  "2025-2026",
		Name:          "默认节次",
		Status:        "published",
		Periods:       datatypes.JSON([]byte(`[{"section":1,"start_time":"08:00","end_time":"09:00"}]`)),
		EffectiveFrom: time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC),
		EffectiveTo:   time.Date(2026, 12, 31, 0, 0, 0, 0, time.UTC),
		PublishedAt:   &publishedAt,
	}).Error)
}

func assertNoSensitiveRemoteFields(t *testing.T, value interface{}) {
	t.Helper()
	forbidden := map[string]struct{}{
		"user_id": {}, "student_id": {}, "name": {}, "real_name": {}, "姓名": {}, "学号": {},
		"phone": {}, "password": {}, "cookie": {}, "cookies": {}, "token": {}, "jwt": {}, "authorization": {},
	}
	assertNoSensitiveRemoteValue(t, value, forbidden)
}

func assertNoSensitiveRemoteValue(t *testing.T, value interface{}, forbidden map[string]struct{}) {
	t.Helper()
	switch typed := value.(type) {
	case map[string]interface{}:
		for key, child := range typed {
			_, exists := forbidden[strings.ToLower(strings.TrimSpace(key))]
			require.Falsef(t, exists, "远端请求不应包含敏感字段 %q", key)
			assertNoSensitiveRemoteValue(t, child, forbidden)
		}
	case []interface{}:
		for _, child := range typed {
			assertNoSensitiveRemoteValue(t, child, forbidden)
		}
	case []map[string]interface{}:
		for _, child := range typed {
			assertNoSensitiveRemoteValue(t, child, forbidden)
		}
	}
}
