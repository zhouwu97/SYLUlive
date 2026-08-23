package services

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"strings"
	"time"

	"github.com/google/uuid"
	"gorm.io/datatypes"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"

	"shenliyuan/internal/models"
)

const (
	deviceJobMaxArgumentsBytes  = 16 << 10
	deviceJobMaxResultBytes     = 256 << 10
	deviceOnlineTTL             = 2 * time.Minute
	requiredDeviceBridgeVersion = 2
)

var deviceToolRequirements = map[string][]string{
	"device.academic.get_cached_overview":         {"academic"},
	"device.academic.get_cached_grade_summary":    {"grades"},
	"device.academic.get_cached_risk_context":     {"grades"},
	"device.schedule.get_cached_week":             {"schedule"},
	"device.academic.get_credit_summary":          {"academic"},
	"device.erke.get_cached_overview":             {"erke"},
	"device.academic.ensure_fresh_overview":       {"academic"},
	"device.academic.ensure_fresh_grade_summary":  {"grades"},
	"device.academic.ensure_fresh_risk_context":   {"grades"},
	"device.schedule.ensure_fresh_week":           {"schedule"},
	"device.academic.ensure_fresh_credit_summary": {"academic"},
	"device.erke.ensure_fresh_overview":           {"erke"},
}

type DeviceJobError struct {
	Code string
}

func (e *DeviceJobError) Error() string { return e.Code }

func newDeviceJobError(code string) error { return &DeviceJobError{Code: code} }

// DeviceRegistration 表示设备主动作业能力。工具集合只能缩小服务端白名单。
type DeviceRegistration struct {
	InstallationID        string
	PushToken             string
	ToolNames             []string
	BridgeProtocolVersion int
	ClientVersion         string
}

type CreateDeviceJobRequest struct {
	UserID            uint
	RunID             string
	ToolCallID        string
	ToolName          string
	Arguments         json.RawMessage
	RequiredDataTypes []string
	ExpiresAt         time.Time
}

// DeviceJobService 管理临时设备工具任务；它不读取设备缓存，也不保存设备密钥。
type DeviceJobService struct {
	db    *gorm.DB
	clock func() time.Time
}

func NewDeviceJobService(db *gorm.DB) *DeviceJobService {
	return &DeviceJobService{db: db, clock: time.Now}
}

func (s *DeviceJobService) RegisterDevice(ctx context.Context, userID uint, registration DeviceRegistration) (*models.UserDevice, error) {
	if userID == 0 {
		return nil, newDeviceJobError("unauthorized")
	}
	registration.InstallationID = strings.TrimSpace(registration.InstallationID)
	registration.PushToken = strings.TrimSpace(registration.PushToken)
	registration.ClientVersion = strings.TrimSpace(registration.ClientVersion)
	if registration.BridgeProtocolVersion == 0 {
		// 旧客户端没有登记协议版本；保留登记记录，并在调度新协议任务时给出明确升级提示。
		registration.BridgeProtocolVersion = 1
	}
	tools, err := normalizeDeviceTools(registration.ToolNames)
	if err != nil || registration.InstallationID == "" || len(registration.InstallationID) > 128 ||
		registration.BridgeProtocolVersion < 1 || registration.BridgeProtocolVersion > 1000 || len(registration.ClientVersion) > 32 {
		return nil, newDeviceJobError("invalid_device_registration")
	}
	encodedTools, _ := json.Marshal(tools)
	now := s.clock().UTC()
	var result models.UserDevice
	err = s.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		var existing models.UserDevice
		err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).
			Where("installation_id = ?", registration.InstallationID).First(&existing).Error
		if errors.Is(err, gorm.ErrRecordNotFound) {
			result = models.UserDevice{
				ID: uuid.NewString(), UserID: userID, InstallationID: registration.InstallationID,
				PushToken: registration.PushToken, ToolNames: datatypes.JSON(encodedTools),
				BridgeProtocolVersion: registration.BridgeProtocolVersion, ClientVersion: registration.ClientVersion, LastSeenAt: now,
			}
			return tx.Create(&result).Error
		}
		if err != nil {
			return err
		}
		if existing.UserID != userID {
			// 同一 App 安装切换账号时，旧账号未完成任务必须失效，避免后续串读。
			if err := tx.Model(&models.DeviceToolJob{}).
				Where("user_id = ? AND installation_id = ? AND status IN ?", existing.UserID, registration.InstallationID, activeDeviceJobStates()).
				Updates(map[string]interface{}{"status": models.DeviceToolJobCancelled, "error_code": "device_account_changed", "state_version": gorm.Expr("state_version + 1")}).Error; err != nil {
				return err
			}
		}
		if err := tx.Model(&models.UserDevice{}).Where("id = ?", existing.ID).Updates(map[string]interface{}{
			"user_id": userID, "push_token": registration.PushToken, "tool_names": datatypes.JSON(encodedTools),
			"bridge_protocol_version": registration.BridgeProtocolVersion, "client_version": registration.ClientVersion,
			"last_seen_at": now, "revoked_at": nil,
		}).Error; err != nil {
			return err
		}
		return tx.Where("id = ?", existing.ID).First(&result).Error
	})
	if err != nil {
		return nil, err
	}
	return &result, nil
}

// CreateJob 仅供经过工具白名单和用户授权的服务端调用。模型传入的参数中不能含 user_id。
func (s *DeviceJobService) CreateJob(ctx context.Context, request CreateDeviceJobRequest) (*models.DeviceToolJob, error) {
	if request.UserID == 0 || strings.TrimSpace(request.RunID) == "" || strings.TrimSpace(request.ToolCallID) == "" {
		return nil, newDeviceJobError("invalid_device_job")
	}
	required, ok := deviceToolRequirements[request.ToolName]
	if !ok || !sameStringSet(required, request.RequiredDataTypes) {
		return nil, newDeviceJobError("tool_not_allowed")
	}
	arguments, err := normalizeDeviceJSON(request.Arguments, deviceJobMaxArgumentsBytes)
	if err != nil || containsForbiddenIdentity(arguments) || !validDeviceToolArguments(request.ToolName, arguments) {
		return nil, newDeviceJobError("invalid_tool_arguments")
	}
	arguments = clampDeviceFreshnessArguments(request.ToolName, arguments)
	var existing models.DeviceToolJob
	lookupErr := s.db.WithContext(ctx).
		Where("user_id = ? AND run_id = ? AND tool_call_id = ?", request.UserID, strings.TrimSpace(request.RunID), strings.TrimSpace(request.ToolCallID)).
		First(&existing).Error
	if lookupErr == nil {
		return &existing, nil
	}
	if !errors.Is(lookupErr, gorm.ErrRecordNotFound) {
		return nil, lookupErr
	}
	now := s.clock().UTC()
	expiresAt := request.ExpiresAt.UTC()
	if expiresAt.IsZero() {
		expiresAt = now.Add(2 * time.Minute)
	}
	if !expiresAt.After(now) || expiresAt.After(now.Add(10*time.Minute)) {
		return nil, newDeviceJobError("invalid_job_expiry")
	}
	device, err := s.findDeviceForTool(ctx, request.UserID, request.ToolName)
	if err != nil {
		return nil, err
	}
	requiredJSON, _ := json.Marshal(required)
	job := models.DeviceToolJob{
		ID: uuid.NewString(), UserID: request.UserID, RunID: strings.TrimSpace(request.RunID),
		ToolCallID: strings.TrimSpace(request.ToolCallID), InstallationID: device.InstallationID,
		ToolName: request.ToolName, ArgumentsJSON: datatypes.JSON(arguments), RequiredDataTypes: datatypes.JSON(requiredJSON),
		Status: models.DeviceToolJobPending, ExpiresAt: expiresAt,
	}
	if err := s.db.WithContext(ctx).Create(&job).Error; err != nil {
		// 并发重试可能已经由另一请求创建了同一 tool call；唯一索引负责
		// 最终裁决，此处返回已有 Job 让 Run resume 保持幂等。
		if lookupErr := s.db.WithContext(ctx).
			Where("user_id = ? AND run_id = ? AND tool_call_id = ?", request.UserID, job.RunID, job.ToolCallID).
			First(&existing).Error; lookupErr == nil {
			return &existing, nil
		}
		return nil, err
	}
	return &job, nil
}

// findDeviceForTool 只选择显式声明支持目标工具的当前账号设备，避免把任务推给无法安全执行它的旧客户端。
func (s *DeviceJobService) findDeviceForTool(ctx context.Context, userID uint, toolName string) (models.UserDevice, error) {
	var devices []models.UserDevice
	now := s.clock().UTC()
	if err := s.db.WithContext(ctx).
		Where("user_id = ? AND revoked_at IS NULL AND last_seen_at >= ?", userID, now.Add(-deviceOnlineTTL)).
		Order("last_seen_at DESC").Find(&devices).Error; err != nil {
		return models.UserDevice{}, err
	}
	clientOutdated := false
	for _, device := range devices {
		var tools []string
		if json.Unmarshal(device.ToolNames, &tools) != nil {
			continue
		}
		for _, tool := range tools {
			if tool == toolName {
				if device.BridgeProtocolVersion < requiredDeviceBridgeVersion {
					clientOutdated = true
					continue
				}
				return device, nil
			}
		}
	}
	if clientOutdated {
		return models.UserDevice{}, newDeviceJobError("device_client_outdated")
	}
	return models.UserDevice{}, newDeviceJobError("device_offline")
}

// PushPayload 返回允许发送给推送服务的最小正文；调用方不得向其中追加个人数据。
func (s *DeviceJobService) PushPayload(job *models.DeviceToolJob) map[string]string {
	return map[string]string{"type": "ai_device_job", "job_id": job.ID}
}

func (s *DeviceJobService) PendingJobs(ctx context.Context, userID uint, installationID string) ([]models.DeviceToolJob, error) {
	if err := s.requireActiveDevice(ctx, userID, installationID); err != nil {
		return nil, err
	}
	now := s.clock().UTC()
	if err := s.expireDue(ctx, userID, installationID, now); err != nil {
		return nil, err
	}
	var jobs []models.DeviceToolJob
	err := s.db.WithContext(ctx).
		Where("user_id = ? AND installation_id = ? AND status IN ? AND expires_at > ?", userID, installationID, []string{models.DeviceToolJobPending, models.DeviceToolJobPushed, models.DeviceToolJobWaitingUser}, now).
		Order("created_at ASC").Limit(20).Find(&jobs).Error
	return jobs, err
}

func (s *DeviceJobService) GetJob(ctx context.Context, userID uint, installationID, jobID string) (*models.DeviceToolJob, error) {
	if err := s.requireActiveDevice(ctx, userID, installationID); err != nil {
		return nil, err
	}
	job, err := s.getOwnedJob(ctx, userID, installationID, jobID)
	if err != nil {
		return nil, err
	}
	if job.ExpiresAt.Before(s.clock().UTC()) && isActiveDeviceJobState(job.Status) {
		if err := s.markExpired(ctx, job); err != nil {
			return nil, err
		}
		return nil, newDeviceJobError("job_expired")
	}
	return job, nil
}

func (s *DeviceJobService) ClaimJob(ctx context.Context, userID uint, installationID, jobID string, stateVersion int64) (*models.DeviceToolJob, error) {
	if stateVersion < 0 {
		return nil, newDeviceJobError("invalid_state_version")
	}
	if err := s.requireActiveDevice(ctx, userID, installationID); err != nil {
		return nil, err
	}
	now := s.clock().UTC()
	var result models.DeviceToolJob
	err := s.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		var job models.DeviceToolJob
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).
			Where("id = ? AND user_id = ? AND installation_id = ?", jobID, userID, installationID).First(&job).Error; err != nil {
			return mapDeviceJobNotFound(err)
		}
		if !job.ExpiresAt.After(now) {
			return expireLockedJob(tx, &job, now)
		}
		if job.StateVersion != stateVersion {
			return newDeviceJobError("state_version_conflict")
		}
		if job.Status != models.DeviceToolJobPending && job.Status != models.DeviceToolJobPushed && job.Status != models.DeviceToolJobWaitingUser {
			return newDeviceJobError("invalid_job_state")
		}
		updates := map[string]interface{}{"status": models.DeviceToolJobClaimed, "claimed_at": now, "state_version": gorm.Expr("state_version + 1")}
		if err := tx.Model(&models.DeviceToolJob{}).Where("id = ? AND state_version = ? AND status IN ?", job.ID, stateVersion, []string{models.DeviceToolJobPending, models.DeviceToolJobPushed, models.DeviceToolJobWaitingUser}).Updates(updates).Error; err != nil {
			return err
		}
		return tx.Where("id = ?", job.ID).First(&result).Error
	})
	if err != nil {
		return nil, err
	}
	return &result, nil
}

// ProgressJob 接受设备桥接的固定阶段，不接受客户端自定义文案或任意状态。
func (s *DeviceJobService) ProgressJob(ctx context.Context, userID uint, installationID, jobID string, stateVersion int64, stage string) (*models.DeviceToolJob, error) {
	if stateVersion < 0 || !validDeviceJobStage(stage) {
		return nil, newDeviceJobError("invalid_progress_stage")
	}
	if err := s.requireActiveDevice(ctx, userID, installationID); err != nil {
		return nil, err
	}
	now := s.clock().UTC()
	var result models.DeviceToolJob
	err := s.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		var job models.DeviceToolJob
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).
			Where("id = ? AND user_id = ? AND installation_id = ?", jobID, userID, installationID).First(&job).Error; err != nil {
			return mapDeviceJobNotFound(err)
		}
		if !job.ExpiresAt.After(now) {
			return expireLockedJob(tx, &job, now)
		}
		if job.StateVersion != stateVersion || !isProgressTransitionAllowed(job, stage) {
			return newDeviceJobError("state_version_conflict")
		}
		updates := map[string]interface{}{"progress_stage": stage, "state_version": gorm.Expr("state_version + 1")}
		if stage == models.DeviceJobStageRefreshStarted || stage == models.DeviceJobStageReadingResult {
			updates["status"] = models.DeviceToolJobRunning
		}
		if stage == models.DeviceJobStageRefreshFailed {
			// 仅记录真实刷新阶段；FailJob 仍负责统一终态和错误码。
		}
		if err := tx.Model(&models.DeviceToolJob{}).Where("id = ? AND state_version = ?", job.ID, stateVersion).Updates(updates).Error; err != nil {
			return err
		}
		return tx.Where("id = ?", job.ID).First(&result).Error
	})
	if err != nil {
		return nil, err
	}
	return &result, nil
}

func (s *DeviceJobService) CompleteJob(ctx context.Context, userID uint, installationID, jobID string, stateVersion int64, result json.RawMessage) (*models.DeviceToolJob, error) {
	normalized, err := normalizeDeviceJSON(result, deviceJobMaxResultBytes)
	if err != nil || containsForbiddenIdentity(normalized) {
		return nil, newDeviceJobError("invalid_tool_result")
	}
	job, err := s.getOwnedJob(ctx, userID, installationID, jobID)
	if err != nil {
		return nil, err
	}
	if job.StateVersion != stateVersion {
		return nil, newDeviceJobError("state_version_conflict")
	}
	if !validDeviceToolResult(*job, normalized) {
		return nil, newDeviceJobError("invalid_tool_result")
	}
	hash := sha256.Sum256(normalized)
	return s.finishJob(ctx, userID, installationID, jobID, stateVersion, map[string]interface{}{
		"status": models.DeviceToolJobCompleted, "completed_at": s.clock().UTC(), "result_json": datatypes.JSON(normalized),
		"result_hash": hex.EncodeToString(hash[:]), "error_code": "",
	})
}

// validDeviceToolResult 将设备回传固定为每个工具的最小化结果信封，阻止客户端把完整缓存或任意字段写入服务端。
func validDeviceToolResult(job models.DeviceToolJob, value json.RawMessage) bool {
	var envelope map[string]json.RawMessage
	if json.Unmarshal(value, &envelope) != nil || (!hasExactJSONKeys(envelope, []string{
		"data", "source", "fetched_at", "expires_at", "is_stale", "is_partial", "warnings", "evidence",
	}) && !hasExactJSONKeys(envelope, []string{
		"data", "source", "freshness", "refresh_performed", "fetched_at", "expires_at", "is_stale", "is_partial", "warnings", "evidence",
	})) {
		return false
	}
	ensureFresh := strings.Contains(job.ToolName, ".ensure_fresh_")
	if (!jsonStringEquals(envelope["source"], "device_encrypted_cache") &&
		(!ensureFresh || !jsonStringEquals(envelope["source"], "remote_edu_fetch"))) ||
		!validOptionalRFC3339(envelope["fetched_at"]) || !validOptionalRFC3339(envelope["expires_at"]) ||
		!validJSONBool(envelope["is_stale"]) || !validJSONBool(envelope["is_partial"]) ||
		!validLimitedStringArray(envelope["warnings"], 16, 240) || !validDeviceEvidence(envelope["evidence"], ensureFresh) {
		return false
	}
	if _, extended := envelope["freshness"]; extended {
		if !validFreshness(envelope["freshness"]) || !validJSONBool(envelope["refresh_performed"]) {
			return false
		}
	}
	if ensureFresh {
		// ensure_fresh 的语义是“返回时已满足新鲜度”，而不是“尝试过刷新”。
		// 客户端即使刷新失败，也不能把旧缓存伪装成远端新数据回传。
		var freshness map[string]json.RawMessage
		if json.Unmarshal(envelope["freshness"], &freshness) != nil ||
			!jsonStringEquals(freshness["after"], "fresh") ||
			!jsonBoolEquals(envelope["is_stale"], false) {
			return false
		}
		var refreshPerformed bool
		if json.Unmarshal(envelope["refresh_performed"], &refreshPerformed) != nil {
			return false
		}
		if refreshPerformed && !jsonStringEquals(envelope["source"], "remote_edu_fetch") {
			return false
		}
	}
	var data map[string]json.RawMessage
	if json.Unmarshal(envelope["data"], &data) != nil {
		return false
	}
	return validDeviceToolData(job, data)
}

func validDeviceToolData(job models.DeviceToolJob, data map[string]json.RawMessage) bool {
	switch job.ToolName {
	case "device.academic.get_cached_overview", "device.academic.ensure_fresh_overview":
		if !hasExactJSONKeys(data, []string{"total_recorded_courses", "covered_term_count", "covered_terms", "academic_situation_available"}) ||
			!validIntegerRange(data["total_recorded_courses"], 0, 500) || !validIntegerRange(data["covered_term_count"], 0, 32) || !validJSONBool(data["academic_situation_available"]) {
			return false
		}
		return validAcademicTerms(data["covered_terms"], data["covered_term_count"])
	case "device.academic.get_cached_grade_summary", "device.academic.ensure_fresh_grade_summary",
		"device.academic.get_cached_risk_context", "device.academic.ensure_fresh_risk_context":
		return validAcademicGradeSummary(data)
	case "device.schedule.get_cached_week", "device.schedule.ensure_fresh_week":
		if !hasExactJSONKeys(data, []string{"week_start", "week_end", "courses"}) ||
			!validDateString(data["week_start"]) || !validDateString(data["week_end"]) {
			return false
		}
		requested, ok := parseWeekContaining(json.RawMessage(job.ArgumentsJSON))
		if !ok {
			return false
		}
		expectedStart := mondayOf(requested)
		expectedEnd := expectedStart.AddDate(0, 0, 6)
		weekStart, startOK := decodeDate(data["week_start"])
		weekEnd, endOK := decodeDate(data["week_end"])
		if !startOK || !endOK || !weekStart.Equal(expectedStart) || !weekEnd.Equal(expectedEnd) {
			return false
		}
		return validScheduleCourses(data["courses"], weekStart, weekEnd)
	case "device.academic.get_credit_summary", "device.academic.ensure_fresh_credit_summary":
		if !hasExactJSONKeys(data, []string{"attempted_credits", "passed_credits", "failed_credits", "required_failed_credits", "unknown_credits"}) ||
			!validNumberRange(data["attempted_credits"], 0, 10000) || !validNumberRange(data["passed_credits"], 0, 10000) || !validNumberRange(data["failed_credits"], 0, 10000) || !validNumberRange(data["required_failed_credits"], 0, 10000) || !validNumberRange(data["unknown_credits"], 0, 10000) {
			return false
		}
		attempted, _ := decodeNumber(data["attempted_credits"])
		passed, _ := decodeNumber(data["passed_credits"])
		failed, _ := decodeNumber(data["failed_credits"])
		requiredFailed, _ := decodeNumber(data["required_failed_credits"])
		return passed+failed <= attempted && requiredFailed <= failed
	case "device.erke.get_cached_overview", "device.erke.ensure_fresh_overview":
		if !hasExactJSONKeys(data, []string{"earned_total", "required_total", "unmet_categories", "activity_count", "latest_activity_date"}) ||
			!validOptionalJSONNumber(data["earned_total"]) || !validOptionalJSONNumber(data["required_total"]) ||
			!validIntegerRange(data["activity_count"], 0, 100000) || !validOptionalString(data["latest_activity_date"], 10) {
			return false
		}
		return validErkeCategories(data["unmet_categories"])
	default:
		return false
	}
}

func validAcademicTerms(value, count json.RawMessage) bool {
	var terms []map[string]json.RawMessage
	if string(value) == "null" || json.Unmarshal(value, &terms) != nil || len(terms) > 32 {
		return false
	}
	if decoded, ok := decodeInteger(count); !ok || decoded != len(terms) {
		return false
	}
	for _, term := range terms {
		if !hasExactJSONKeys(term, []string{"year", "semester", "course_count"}) ||
			!validJSONString(term["year"], 16) || !validIntegerRange(term["semester"], 1, 3) || !validIntegerRange(term["course_count"], 0, 500) {
			return false
		}
	}
	return true
}

func validScheduleCourses(value json.RawMessage, weekStart, weekEnd time.Time) bool {
	var courses []map[string]json.RawMessage
	if string(value) == "null" || json.Unmarshal(value, &courses) != nil || len(courses) > 32 {
		return false
	}
	for _, course := range courses {
		if !hasExactJSONKeys(course, []string{"date", "course_name", "start_section", "end_section"}) ||
			!validDateString(course["date"]) || !validJSONString(course["course_name"], 160) ||
			!validIntegerRange(course["start_section"], 1, 30) || !validIntegerRange(course["end_section"], 1, 30) {
			return false
		}
		date, ok := decodeDate(course["date"])
		if !ok || date.Before(weekStart) || date.After(weekEnd) {
			return false
		}
		start, _ := decodeInteger(course["start_section"])
		end, _ := decodeInteger(course["end_section"])
		if end < start {
			return false
		}
	}
	return true
}

func validErkeCategories(value json.RawMessage) bool {
	var categories []map[string]json.RawMessage
	if string(value) == "null" || json.Unmarshal(value, &categories) != nil || len(categories) > 16 {
		return false
	}
	for _, category := range categories {
		if !hasExactJSONKeys(category, []string{"name", "gap"}) || !validJSONString(category["name"], 80) || !validNumberRange(category["gap"], 0, 10000) {
			return false
		}
	}
	return true
}

func validDeviceEvidence(value json.RawMessage, allowRemote bool) bool {
	var evidence []map[string]json.RawMessage
	if string(value) == "null" || json.Unmarshal(value, &evidence) != nil || len(evidence) > 4 {
		return false
	}
	for _, item := range evidence {
		if !hasExactJSONKeys(item, []string{"source", "fetched_at", "expires_at", "is_stale"}) ||
			(!jsonStringEquals(item["source"], "device_encrypted_cache") &&
				(!allowRemote || !jsonStringEquals(item["source"], "remote_edu_fetch"))) ||
			!validOptionalRFC3339(item["fetched_at"]) ||
			!validOptionalRFC3339(item["expires_at"]) || !validJSONBool(item["is_stale"]) {
			return false
		}
	}
	return true
}

func validFreshness(value json.RawMessage) bool {
	var freshness map[string]json.RawMessage
	if json.Unmarshal(value, &freshness) != nil ||
		!hasExactJSONKeys(freshness, []string{"before", "after"}) {
		return false
	}
	return validFreshnessLabel(freshness["before"]) && validFreshnessLabel(freshness["after"])
}

func validFreshnessLabel(value json.RawMessage) bool {
	var label string
	if json.Unmarshal(value, &label) != nil {
		return false
	}
	return label == "fresh" || label == "stale"
}

func hasExactJSONKeys(value map[string]json.RawMessage, expected []string) bool {
	if len(value) != len(expected) {
		return false
	}
	for _, key := range expected {
		if _, ok := value[key]; !ok {
			return false
		}
	}
	return true
}

func validJSONBool(value json.RawMessage) bool {
	var decoded bool
	return string(value) != "null" && json.Unmarshal(value, &decoded) == nil
}

func jsonBoolEquals(value json.RawMessage, expected bool) bool {
	var decoded bool
	return json.Unmarshal(value, &decoded) == nil && decoded == expected
}

func validJSONNumber(value json.RawMessage) bool {
	_, ok := decodeNumber(value)
	return ok
}

func validIntegerRange(value json.RawMessage, min, max int) bool {
	decoded, ok := decodeInteger(value)
	return ok && decoded >= min && decoded <= max
}
func validNumberRange(value json.RawMessage, min, max float64) bool {
	decoded, ok := decodeNumber(value)
	return ok && decoded >= min && decoded <= max
}
func decodeNumber(value json.RawMessage) (float64, bool) {
	var decoded float64
	if string(value) == "null" || json.Unmarshal(value, &decoded) != nil || math.IsNaN(decoded) || math.IsInf(decoded, 0) {
		return 0, false
	}
	return decoded, true
}
func decodeInteger(value json.RawMessage) (int, bool) {
	decoded, ok := decodeNumber(value)
	if !ok || math.Trunc(decoded) != decoded || decoded < math.MinInt || decoded > math.MaxInt {
		return 0, false
	}
	return int(decoded), true
}

func validOptionalJSONNumber(value json.RawMessage) bool {
	if string(value) == "null" {
		return true
	}
	return validJSONNumber(value)
}

func validJSONString(value json.RawMessage, maxLength int) bool {
	var decoded string
	return json.Unmarshal(value, &decoded) == nil && decoded != "" && len(decoded) <= maxLength
}

func validOptionalString(value json.RawMessage, maxLength int) bool {
	if string(value) == "null" {
		return true
	}
	return validJSONString(value, maxLength)
}

func jsonStringEquals(value json.RawMessage, expected string) bool {
	var decoded string
	return json.Unmarshal(value, &decoded) == nil && decoded == expected
}

func validOptionalRFC3339(value json.RawMessage) bool {
	if string(value) == "null" {
		return true
	}
	var decoded string
	if json.Unmarshal(value, &decoded) != nil {
		return false
	}
	_, err := time.Parse(time.RFC3339, decoded)
	return err == nil
}

func validDateString(value json.RawMessage) bool {
	_, ok := decodeDate(value)
	return ok
}

func validDeviceToolArguments(toolName string, value json.RawMessage) bool {
	var arguments map[string]json.RawMessage
	if json.Unmarshal(value, &arguments) != nil {
		return false
	}
	switch toolName {
	case "device.schedule.get_cached_week":
		return hasExactJSONKeys(arguments, []string{"week_containing"}) && validDateString(arguments["week_containing"])
	case "device.academic.get_cached_overview", "device.academic.get_credit_summary", "device.erke.get_cached_overview",
		"device.academic.get_cached_grade_summary", "device.academic.get_cached_risk_context":
		return len(arguments) == 0
	case "device.schedule.ensure_fresh_week":
		return hasExactJSONKeys(arguments, []string{"week_containing", "max_age_seconds"}) &&
			validDateString(arguments["week_containing"]) && validMaxAgeSeconds(arguments["max_age_seconds"])
	case "device.academic.ensure_fresh_overview", "device.academic.ensure_fresh_grade_summary", "device.academic.ensure_fresh_risk_context", "device.academic.ensure_fresh_credit_summary", "device.erke.ensure_fresh_overview":
		return hasExactJSONKeys(arguments, []string{"max_age_seconds"}) && validMaxAgeSeconds(arguments["max_age_seconds"])
	default:
		return false
	}
}

func validAcademicGradeSummary(data map[string]json.RawMessage) bool {
	if !hasExactJSONKeys(data, []string{"course_count", "earned_credits", "weighted_gpa", "failed_courses"}) ||
		!validIntegerRange(data["course_count"], 0, 500) ||
		!validNumberRange(data["earned_credits"], 0, 10000) ||
		!validNumberRange(data["weighted_gpa"], 0, 4) {
		return false
	}
	var courses []map[string]json.RawMessage
	if json.Unmarshal(data["failed_courses"], &courses) != nil || len(courses) > 500 {
		return false
	}
	for _, course := range courses {
		if !hasExactJSONKeys(course, []string{"course_name", "grade", "credits"}) ||
			!validJSONString(course["course_name"], 200) ||
			!validNumberRange(course["grade"], 0, 100) ||
			!validNumberRange(course["credits"], 0, 100) {
			return false
		}
	}
	return true
}

func validMaxAgeSeconds(value json.RawMessage) bool {
	var seconds float64
	if json.Unmarshal(value, &seconds) != nil || seconds != math.Trunc(seconds) {
		return false
	}
	return seconds > 0 && seconds <= 24*60*60
}

// clampDeviceFreshnessArguments 把模型的意图收窄到服务端策略边界；设备仍会在
// 最终执行前依据本地 fetched_at / expires_at 再判断一次。
func clampDeviceFreshnessArguments(toolName string, value json.RawMessage) json.RawMessage {
	if !strings.Contains(toolName, ".ensure_fresh_") {
		return value
	}
	var arguments map[string]json.RawMessage
	if json.Unmarshal(value, &arguments) != nil {
		return value
	}
	var requested float64
	if json.Unmarshal(arguments["max_age_seconds"], &requested) != nil {
		return value
	}
	minimum := 300.0
	if strings.Contains(toolName, "schedule") {
		minimum = 600
	} else if strings.Contains(toolName, "erke") {
		minimum = 1800
	}
	if requested < minimum {
		arguments["max_age_seconds"], _ = json.Marshal(minimum)
	}
	encoded, err := json.Marshal(arguments)
	if err != nil {
		return value
	}
	return encoded
}

func parseWeekContaining(value json.RawMessage) (time.Time, bool) {
	var arguments map[string]json.RawMessage
	if json.Unmarshal(value, &arguments) != nil {
		return time.Time{}, false
	}
	return decodeDate(arguments["week_containing"])
}

func decodeDate(value json.RawMessage) (time.Time, bool) {
	var decoded string
	if json.Unmarshal(value, &decoded) != nil || len(decoded) != len("2006-01-02") {
		return time.Time{}, false
	}
	parsed, err := time.Parse("2006-01-02", decoded)
	if err != nil {
		return time.Time{}, false
	}
	return parsed, true
}

func mondayOf(value time.Time) time.Time {
	return value.AddDate(0, 0, -((int(value.Weekday()) + 6) % 7))
}

func validLimitedStringArray(value json.RawMessage, maxItems, maxLength int) bool {
	var values []string
	if string(value) == "null" || json.Unmarshal(value, &values) != nil || len(values) > maxItems {
		return false
	}
	for _, item := range values {
		if item == "" || len(item) > maxLength {
			return false
		}
	}
	return true
}

func (s *DeviceJobService) FailJob(ctx context.Context, userID uint, installationID, jobID string, stateVersion int64, errorCode string) (*models.DeviceToolJob, error) {
	errorCode = strings.TrimSpace(errorCode)
	if errorCode == "" || len(errorCode) > 64 || !isSafeErrorCode(errorCode) {
		return nil, newDeviceJobError("invalid_error_code")
	}
	return s.finishJob(ctx, userID, installationID, jobID, stateVersion, map[string]interface{}{
		"status": models.DeviceToolJobFailed, "completed_at": s.clock().UTC(), "error_code": errorCode,
	})
}

func (s *DeviceJobService) CancelJob(ctx context.Context, userID uint, installationID, jobID string, stateVersion int64) (*models.DeviceToolJob, error) {
	return s.finishJob(ctx, userID, installationID, jobID, stateVersion, map[string]interface{}{
		"status": models.DeviceToolJobCancelled, "completed_at": s.clock().UTC(), "error_code": "cancelled_by_device",
	})
}

func (s *DeviceJobService) finishJob(ctx context.Context, userID uint, installationID, jobID string, stateVersion int64, updates map[string]interface{}) (*models.DeviceToolJob, error) {
	if stateVersion < 0 {
		return nil, newDeviceJobError("invalid_state_version")
	}
	if err := s.requireActiveDevice(ctx, userID, installationID); err != nil {
		return nil, err
	}
	now := s.clock().UTC()
	var result models.DeviceToolJob
	err := s.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		var job models.DeviceToolJob
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).
			Where("id = ? AND user_id = ? AND installation_id = ?", jobID, userID, installationID).First(&job).Error; err != nil {
			return mapDeviceJobNotFound(err)
		}
		if !job.ExpiresAt.After(now) {
			return expireLockedJob(tx, &job, now)
		}
		if job.StateVersion != stateVersion {
			return newDeviceJobError("state_version_conflict")
		}
		if job.Status != models.DeviceToolJobClaimed && job.Status != models.DeviceToolJobRunning && job.Status != models.DeviceToolJobWaitingUser {
			return newDeviceJobError("invalid_job_state")
		}
		updates["state_version"] = gorm.Expr("state_version + 1")
		if err := tx.Model(&models.DeviceToolJob{}).Where("id = ? AND state_version = ? AND status IN ?", job.ID, stateVersion, []string{models.DeviceToolJobClaimed, models.DeviceToolJobRunning, models.DeviceToolJobWaitingUser}).Updates(updates).Error; err != nil {
			return err
		}
		return tx.Where("id = ?", job.ID).First(&result).Error
	})
	if err != nil {
		return nil, err
	}
	return &result, nil
}

func (s *DeviceJobService) requireActiveDevice(ctx context.Context, userID uint, installationID string) error {
	installationID = strings.TrimSpace(installationID)
	if userID == 0 || installationID == "" {
		return newDeviceJobError("device_not_registered")
	}
	now := s.clock().UTC()
	result := s.db.WithContext(ctx).Model(&models.UserDevice{}).
		Where("user_id = ? AND installation_id = ? AND revoked_at IS NULL", userID, installationID).
		Updates(map[string]interface{}{"last_seen_at": now})
	if result.Error != nil {
		return result.Error
	}
	if result.RowsAffected != 1 {
		return newDeviceJobError("device_not_registered")
	}
	return nil
}

func (s *DeviceJobService) getOwnedJob(ctx context.Context, userID uint, installationID, jobID string) (*models.DeviceToolJob, error) {
	var job models.DeviceToolJob
	if err := s.db.WithContext(ctx).Where("id = ? AND user_id = ? AND installation_id = ?", jobID, userID, installationID).First(&job).Error; err != nil {
		return nil, mapDeviceJobNotFound(err)
	}
	return &job, nil
}

func (s *DeviceJobService) expireDue(ctx context.Context, userID uint, installationID string, now time.Time) error {
	return s.db.WithContext(ctx).Model(&models.DeviceToolJob{}).
		Where("user_id = ? AND installation_id = ? AND expires_at <= ? AND status IN ?", userID, installationID, now, activeDeviceJobStates()).
		Updates(map[string]interface{}{"status": models.DeviceToolJobExpired, "completed_at": now, "error_code": "job_expired", "state_version": gorm.Expr("state_version + 1")}).Error
}

func (s *DeviceJobService) markExpired(ctx context.Context, job *models.DeviceToolJob) error {
	result := s.db.WithContext(ctx).Model(&models.DeviceToolJob{}).
		Where("id = ? AND state_version = ? AND status IN ?", job.ID, job.StateVersion, activeDeviceJobStates()).
		Updates(map[string]interface{}{"status": models.DeviceToolJobExpired, "completed_at": s.clock().UTC(), "error_code": "job_expired", "state_version": gorm.Expr("state_version + 1")})
	return result.Error
}

func normalizeDeviceTools(values []string) ([]string, error) {
	seen := make(map[string]struct{}, len(values))
	for _, value := range values {
		value = strings.TrimSpace(value)
		if _, ok := deviceToolRequirements[value]; !ok || value == "" {
			return nil, errors.New("unsupported device tool")
		}
		seen[value] = struct{}{}
	}
	if len(seen) == 0 {
		return nil, errors.New("no device tools")
	}
	result := make([]string, 0, len(seen))
	for tool := range seen {
		result = append(result, tool)
	}
	return result, nil
}

func normalizeDeviceJSON(value json.RawMessage, maxBytes int) (json.RawMessage, error) {
	if len(value) == 0 || len(value) > maxBytes || !json.Valid(value) {
		return nil, errors.New("invalid JSON")
	}
	var decoded interface{}
	if err := json.Unmarshal(value, &decoded); err != nil {
		return nil, err
	}
	if decoded == nil {
		return nil, errors.New("null JSON")
	}
	normalized, err := json.Marshal(decoded)
	if err != nil || len(normalized) > maxBytes {
		return nil, errors.New("oversized JSON")
	}
	return normalized, nil
}

func containsForbiddenIdentity(value json.RawMessage) bool {
	var decoded interface{}
	if json.Unmarshal(value, &decoded) != nil {
		return true
	}
	return hasForbiddenIdentity(decoded)
}

func hasForbiddenIdentity(value interface{}) bool {
	switch typed := value.(type) {
	case map[string]interface{}:
		for key, nested := range typed {
			switch strings.ToLower(strings.TrimSpace(key)) {
			case "user_id", "student_id", "source_account_id", "password", "cookie", "token":
				return true
			}
			if hasForbiddenIdentity(nested) {
				return true
			}
		}
	case []interface{}:
		for _, nested := range typed {
			if hasForbiddenIdentity(nested) {
				return true
			}
		}
	}
	return false
}

func sameStringSet(left, right []string) bool {
	if len(left) != len(right) {
		return false
	}
	seen := make(map[string]struct{}, len(left))
	for _, item := range left {
		seen[item] = struct{}{}
	}
	for _, item := range right {
		if _, ok := seen[item]; !ok {
			return false
		}
		delete(seen, item)
	}
	return len(seen) == 0
}

func activeDeviceJobStates() []string {
	return []string{models.DeviceToolJobPending, models.DeviceToolJobPushed, models.DeviceToolJobClaimed, models.DeviceToolJobWaitingUser, models.DeviceToolJobRunning}
}

func validDeviceJobStage(stage string) bool {
	switch stage {
	case models.DeviceJobStageCheckingFreshness, models.DeviceJobStageRequestReceived,
		models.DeviceJobStageRefreshStarted, models.DeviceJobStageRefreshCompleted,
		models.DeviceJobStageRefreshFailed, models.DeviceJobStageReadingResult:
		return true
	default:
		return false
	}
}

func isProgressTransitionAllowed(job models.DeviceToolJob, next string) bool {
	if job.Status != models.DeviceToolJobClaimed && job.Status != models.DeviceToolJobRunning {
		return false
	}
	if next == models.DeviceJobStageRefreshFailed {
		return job.ProgressStage == models.DeviceJobStageRefreshStarted || job.ProgressStage == models.DeviceJobStageCheckingFreshness
	}
	if job.ProgressStage == "" {
		return next == models.DeviceJobStageCheckingFreshness || next == models.DeviceJobStageRequestReceived
	}
	order := map[string]int{
		models.DeviceJobStageCheckingFreshness: 1,
		models.DeviceJobStageRequestReceived:   2,
		models.DeviceJobStageRefreshStarted:    3,
		models.DeviceJobStageRefreshCompleted:  4,
		models.DeviceJobStageReadingResult:     5,
	}
	previous, previousOK := order[job.ProgressStage]
	current, currentOK := order[next]
	if job.ProgressStage == models.DeviceJobStageRequestReceived && next == models.DeviceJobStageReadingResult {
		return true
	}
	return previousOK && currentOK && current == previous+1
}

func isActiveDeviceJobState(status string) bool {
	for _, candidate := range activeDeviceJobStates() {
		if status == candidate {
			return true
		}
	}
	return false
}

func expireLockedJob(tx *gorm.DB, job *models.DeviceToolJob, now time.Time) error {
	if isActiveDeviceJobState(job.Status) {
		if err := tx.Model(&models.DeviceToolJob{}).Where("id = ? AND state_version = ?", job.ID, job.StateVersion).
			Updates(map[string]interface{}{"status": models.DeviceToolJobExpired, "completed_at": now, "error_code": "job_expired", "state_version": gorm.Expr("state_version + 1")}).Error; err != nil {
			return err
		}
	}
	return newDeviceJobError("job_expired")
}

func mapDeviceJobNotFound(err error) error {
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return newDeviceJobError("device_job_not_found")
	}
	return err
}

func isSafeErrorCode(value string) bool {
	for _, char := range value {
		if !(char >= 'a' && char <= 'z') && !(char >= '0' && char <= '9') && char != '_' && char != '-' {
			return false
		}
	}
	return true
}

func (s *DeviceJobService) String() string {
	return fmt.Sprintf("DeviceJobService{%p}", s.db)
}
