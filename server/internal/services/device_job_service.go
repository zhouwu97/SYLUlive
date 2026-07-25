package services

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"
	"gorm.io/datatypes"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"

	"shenliyuan/internal/models"
)

const (
	deviceJobMaxArgumentsBytes = 16 << 10
	deviceJobMaxResultBytes    = 256 << 10
)

var deviceToolRequirements = map[string][]string{
	"device.academic.get_cached_overview": {"academic"},
	"device.schedule.get_cached_week":     {"schedule"},
	"device.academic.get_credit_summary":  {"academic"},
	"device.erke.get_cached_overview":     {"erke"},
}

type DeviceJobError struct {
	Code string
}

func (e *DeviceJobError) Error() string { return e.Code }

func newDeviceJobError(code string) error { return &DeviceJobError{Code: code} }

// DeviceRegistration 表示设备主动作业能力。工具集合只能缩小服务端白名单。
type DeviceRegistration struct {
	InstallationID string
	PushToken      string
	ToolNames      []string
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
	tools, err := normalizeDeviceTools(registration.ToolNames)
	if err != nil || registration.InstallationID == "" || len(registration.InstallationID) > 128 {
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
				PushToken: registration.PushToken, ToolNames: datatypes.JSON(encodedTools), LastSeenAt: now,
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
	if err != nil || containsForbiddenIdentity(arguments) {
		return nil, newDeviceJobError("invalid_tool_arguments")
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
		return nil, err
	}
	return &job, nil
}

// findDeviceForTool 只选择显式声明支持目标工具的当前账号设备，避免把任务推给无法安全执行它的旧客户端。
func (s *DeviceJobService) findDeviceForTool(ctx context.Context, userID uint, toolName string) (models.UserDevice, error) {
	var devices []models.UserDevice
	if err := s.db.WithContext(ctx).
		Where("user_id = ? AND revoked_at IS NULL", userID).
		Order("last_seen_at DESC").Find(&devices).Error; err != nil {
		return models.UserDevice{}, err
	}
	for _, device := range devices {
		var tools []string
		if json.Unmarshal(device.ToolNames, &tools) != nil {
			continue
		}
		for _, tool := range tools {
			if tool == toolName {
				return device, nil
			}
		}
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
		Where("user_id = ? AND installation_id = ? AND status IN ? AND expires_at > ?", userID, installationID, []string{models.DeviceToolJobPending, models.DeviceToolJobPushed}, now).
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
		if job.Status != models.DeviceToolJobPending && job.Status != models.DeviceToolJobPushed {
			return newDeviceJobError("invalid_job_state")
		}
		updates := map[string]interface{}{"status": models.DeviceToolJobClaimed, "claimed_at": now, "state_version": gorm.Expr("state_version + 1")}
		if err := tx.Model(&models.DeviceToolJob{}).Where("id = ? AND state_version = ? AND status IN ?", job.ID, stateVersion, []string{models.DeviceToolJobPending, models.DeviceToolJobPushed}).Updates(updates).Error; err != nil {
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
	if !validDeviceToolResult(job.ToolName, normalized) {
		return nil, newDeviceJobError("invalid_tool_result")
	}
	hash := sha256.Sum256(normalized)
	return s.finishJob(ctx, userID, installationID, jobID, stateVersion, map[string]interface{}{
		"status": models.DeviceToolJobCompleted, "completed_at": s.clock().UTC(), "result_json": datatypes.JSON(normalized),
		"result_hash": hex.EncodeToString(hash[:]), "error_code": "",
	})
}

// validDeviceToolResult 将设备回传固定为每个工具的最小化结果信封，阻止客户端把完整缓存或任意字段写入服务端。
func validDeviceToolResult(toolName string, value json.RawMessage) bool {
	var envelope map[string]json.RawMessage
	if json.Unmarshal(value, &envelope) != nil || !hasExactJSONKeys(envelope, []string{
		"data", "source", "fetched_at", "expires_at", "is_stale", "is_partial", "warnings", "evidence",
	}) {
		return false
	}
	if !jsonStringEquals(envelope["source"], "device_encrypted_cache") ||
		!validOptionalRFC3339(envelope["fetched_at"]) || !validOptionalRFC3339(envelope["expires_at"]) ||
		!validJSONBool(envelope["is_stale"]) || !validJSONBool(envelope["is_partial"]) ||
		!validLimitedStringArray(envelope["warnings"], 16, 240) || !validDeviceEvidence(envelope["evidence"]) {
		return false
	}
	var data map[string]json.RawMessage
	if json.Unmarshal(envelope["data"], &data) != nil {
		return false
	}
	return validDeviceToolData(toolName, data)
}

func validDeviceToolData(toolName string, data map[string]json.RawMessage) bool {
	switch toolName {
	case "device.academic.get_cached_overview":
		if !hasExactJSONKeys(data, []string{"total_recorded_courses", "covered_term_count", "covered_terms", "academic_situation_available"}) ||
			!validJSONNumber(data["total_recorded_courses"]) || !validJSONNumber(data["covered_term_count"]) || !validJSONBool(data["academic_situation_available"]) {
			return false
		}
		return validAcademicTerms(data["covered_terms"])
	case "device.schedule.get_cached_week":
		if !hasExactJSONKeys(data, []string{"week_start", "week_end", "courses"}) ||
			!validDateString(data["week_start"]) || !validDateString(data["week_end"]) {
			return false
		}
		return validScheduleCourses(data["courses"])
	case "device.academic.get_credit_summary":
		return hasExactJSONKeys(data, []string{"attempted_credits", "passed_credits", "failed_credits", "required_failed_credits", "unknown_credits"}) &&
			validJSONNumber(data["attempted_credits"]) && validJSONNumber(data["passed_credits"]) &&
			validJSONNumber(data["failed_credits"]) && validJSONNumber(data["required_failed_credits"]) && validJSONNumber(data["unknown_credits"])
	case "device.erke.get_cached_overview":
		if !hasExactJSONKeys(data, []string{"earned_total", "required_total", "unmet_categories", "activity_count", "latest_activity_date"}) ||
			!validOptionalJSONNumber(data["earned_total"]) || !validOptionalJSONNumber(data["required_total"]) ||
			!validJSONNumber(data["activity_count"]) || !validOptionalString(data["latest_activity_date"], 10) {
			return false
		}
		return validErkeCategories(data["unmet_categories"])
	default:
		return false
	}
}

func validAcademicTerms(value json.RawMessage) bool {
	var terms []map[string]json.RawMessage
	if string(value) == "null" || json.Unmarshal(value, &terms) != nil || len(terms) > 32 {
		return false
	}
	for _, term := range terms {
		if !hasExactJSONKeys(term, []string{"year", "semester", "course_count"}) ||
			!validJSONString(term["year"], 16) || !validJSONNumber(term["semester"]) || !validJSONNumber(term["course_count"]) {
			return false
		}
	}
	return true
}

func validScheduleCourses(value json.RawMessage) bool {
	var courses []map[string]json.RawMessage
	if string(value) == "null" || json.Unmarshal(value, &courses) != nil || len(courses) > 32 {
		return false
	}
	for _, course := range courses {
		if !hasExactJSONKeys(course, []string{"date", "course_name", "start_section", "end_section"}) ||
			!validDateString(course["date"]) || !validJSONString(course["course_name"], 160) ||
			!validJSONNumber(course["start_section"]) || !validJSONNumber(course["end_section"]) {
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
		if !hasExactJSONKeys(category, []string{"name", "gap"}) || !validJSONString(category["name"], 80) || !validJSONNumber(category["gap"]) {
			return false
		}
	}
	return true
}

func validDeviceEvidence(value json.RawMessage) bool {
	var evidence []map[string]json.RawMessage
	if string(value) == "null" || json.Unmarshal(value, &evidence) != nil || len(evidence) > 4 {
		return false
	}
	for _, item := range evidence {
		if !hasExactJSONKeys(item, []string{"source", "fetched_at", "expires_at", "is_stale"}) ||
			!jsonStringEquals(item["source"], "device_encrypted_cache") || !validOptionalRFC3339(item["fetched_at"]) ||
			!validOptionalRFC3339(item["expires_at"]) || !validJSONBool(item["is_stale"]) {
			return false
		}
	}
	return true
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

func validJSONNumber(value json.RawMessage) bool {
	var decoded float64
	return string(value) != "null" && json.Unmarshal(value, &decoded) == nil
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
	var decoded string
	if json.Unmarshal(value, &decoded) != nil || len(decoded) != len("2006-01-02") {
		return false
	}
	_, err := time.Parse("2006-01-02", decoded)
	return err == nil
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
