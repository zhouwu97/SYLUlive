package ai

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"

	"gorm.io/datatypes"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

type PureReadTool interface {
	Name() string
	Version() string
	Definition() ToolDefinition
	Execute(context.Context, uint, json.RawMessage) (interface{}, error)
}

// toolArgumentValidator 允许对高敏感工具在创建审计记录前执行严格参数校验。
// 常规工具保持现有行为；实现该接口的工具可防止未声明的个人数据进入 arguments_json。
type toolArgumentValidator interface {
	ValidateToolArguments(json.RawMessage) error
}

// ToolWait 表示工具需要在外部操作完成后才能给出结果。
// ResumeKey 仅保存作业标识，不能包含成绩、凭据或设备缓存内容。
type ToolWait struct {
	State        string                       `json:"state"`
	EventType    string                       `json:"event_type"`
	ResumeKey    string                       `json:"resume_key,omitempty"`
	ConsentScope models.AIUserPermissionScope `json:"consent_scope,omitempty"`
	Payload      map[string]interface{}       `json:"payload"`
}

// ToolExecutionResult 区分立即可用的工具结果和需要异步恢复的工具等待。
type ToolExecutionResult struct {
	Result json.RawMessage
	Wait   *ToolWait
}

type toolCallContextKey struct{}

type toolCallContext struct {
	RunID    string
	CallID   string
	UserID   uint
	ToolName string
}

func withToolCallContext(ctx context.Context, runID, callID string, userID uint, toolName string) context.Context {
	return context.WithValue(ctx, toolCallContextKey{}, toolCallContext{RunID: runID, CallID: callID, UserID: userID, ToolName: toolName})
}

func currentToolCallContext(ctx context.Context) (toolCallContext, bool) {
	value, ok := ctx.Value(toolCallContextKey{}).(toolCallContext)
	return value, ok && value.RunID != "" && value.CallID != "" && value.UserID != 0
}

type ToolRegistry struct {
	db    *gorm.DB
	tools map[string]PureReadTool
}

func NewToolRegistry(db *gorm.DB, tools ...PureReadTool) (*ToolRegistry, error) {
	registry := &ToolRegistry{db: db, tools: make(map[string]PureReadTool)}
	for _, tool := range tools {
		if tool == nil || tool.Name() == "" {
			return nil, errors.New("invalid AI tool")
		}
		if _, exists := registry.tools[tool.Name()]; exists {
			return nil, fmt.Errorf("duplicate AI tool: %s", tool.Name())
		}
		registry.tools[tool.Name()] = tool
	}
	return registry, nil
}

func (r *ToolRegistry) Definitions() []ToolDefinition {
	result := make([]ToolDefinition, 0, len(r.tools))
	for _, tool := range r.tools {
		result = append(result, tool.Definition())
	}
	sort.Slice(result, func(i, j int) bool { return result[i].Name < result[j].Name })
	return result
}

// Execute 以 call_id 幂等执行纯读工具。userID 只能由 JWT Context 调用方注入。
func (r *ToolRegistry) Execute(ctx context.Context, callID, runID string, userID uint, toolName string, arguments json.RawMessage) (ToolExecutionResult, bool, error) {
	tool, ok := r.tools[toolName]
	if !ok {
		return ToolExecutionResult{}, false, errors.New("tool_not_allowed")
	}
	if callID == "" || runID == "" || userID == 0 || len(arguments) == 0 || len(arguments) > 16<<10 {
		return ToolExecutionResult{}, false, errors.New("invalid_tool_call")
	}
	if !json.Valid(arguments) || containsForbiddenToolIdentity(arguments) {
		return ToolExecutionResult{}, false, errors.New("invalid_tool_call")
	}
	if validator, ok := tool.(toolArgumentValidator); ok {
		if err := validator.ValidateToolArguments(arguments); err != nil {
			return ToolExecutionResult{}, false, errors.New("invalid_tool_call")
		}
	}
	hash := sha256.Sum256(arguments)
	hashText := hex.EncodeToString(hash[:])
	call := models.AIToolCall{
		CallID: callID, RunID: runID, UserID: userID, ToolName: tool.Name(), ToolVersion: tool.Version(),
		ArgumentsJSON: datatypes.JSON(arguments), ArgumentsHash: hashText, Status: "pending",
		ExpiresAt: time.Now().Add(2 * time.Minute),
	}
	err := r.db.WithContext(ctx).Create(&call).Error
	if err != nil {
		var existing models.AIToolCall
		if findErr := r.db.WithContext(ctx).First(&existing, "call_id = ?", callID).Error; findErr != nil {
			return ToolExecutionResult{}, false, err
		}
		if existing.RunID != runID || existing.UserID != userID || existing.ToolName != toolName || existing.ArgumentsHash != hashText {
			return ToolExecutionResult{}, false, errors.New("tool_call_idempotency_conflict")
		}
		if existing.Status == "completed" {
			return ToolExecutionResult{Result: json.RawMessage(existing.ResultJSON)}, true, nil
		}
		return ToolExecutionResult{}, true, errors.New("tool_call_in_progress")
	}
	result := r.db.WithContext(ctx).Model(&models.AIToolCall{}).
		Where("call_id = ? AND status = ? AND state_version = ?", callID, "pending", 0).
		Updates(map[string]interface{}{"status": "running", "state_version": 1})
	if result.Error != nil || result.RowsAffected != 1 {
		return ToolExecutionResult{}, false, errors.New("tool_state_conflict")
	}

	value, executeErr := tool.Execute(withToolCallContext(ctx, runID, callID, userID, toolName), userID, arguments)
	if executeErr != nil {
		now := time.Now()
		_ = r.db.WithContext(ctx).Model(&models.AIToolCall{}).
			Where("call_id = ? AND status = ? AND state_version = ?", callID, "running", 1).
			Updates(map[string]interface{}{"status": "failed", "state_version": 2, "completed_at": now}).Error
		return ToolExecutionResult{}, false, executeErr
	}
	if wait, ok := value.(ToolWait); ok {
		if err := validateToolWait(wait); err != nil {
			return ToolExecutionResult{}, false, err
		}
		result = r.db.WithContext(ctx).Model(&models.AIToolCall{}).
			Where("call_id = ? AND status = ? AND state_version = ?", callID, "running", 1).
			Updates(map[string]interface{}{"status": "waiting", "state_version": 2})
		if result.Error != nil || result.RowsAffected != 1 {
			return ToolExecutionResult{}, false, errors.New("tool_state_conflict")
		}
		return ToolExecutionResult{Wait: &wait}, false, nil
	}
	encoded, err := json.Marshal(value)
	if err != nil || len(encoded) > 256<<10 {
		return ToolExecutionResult{}, false, errors.New("tool_result_invalid")
	}
	resultHash := sha256.Sum256(encoded)
	now := time.Now()
	result = r.db.WithContext(ctx).Model(&models.AIToolCall{}).
		Where("call_id = ? AND status = ? AND state_version = ?", callID, "running", 1).
		Updates(map[string]interface{}{
			"status": "completed", "state_version": 2, "result_json": datatypes.JSON(encoded),
			"result_hash": hex.EncodeToString(resultHash[:]), "completed_at": now,
		})
	if result.Error != nil || result.RowsAffected != 1 {
		return ToolExecutionResult{}, false, errors.New("tool_state_conflict")
	}
	return ToolExecutionResult{Result: encoded}, false, nil
}

// CompleteWaitingCall 将已完成的外部操作结果写回原 Tool Call，保证恢复可重试且不重复执行工具。
func (r *ToolRegistry) CompleteWaitingCall(ctx context.Context, callID string, resultJSON json.RawMessage) error {
	if callID == "" || len(resultJSON) == 0 || len(resultJSON) > 256<<10 || !json.Valid(resultJSON) {
		return errors.New("tool_result_invalid")
	}
	hash := sha256.Sum256(resultJSON)
	result := r.db.WithContext(ctx).Model(&models.AIToolCall{}).
		Where("call_id = ? AND status = ? AND state_version = ?", callID, "waiting", 2).
		Updates(map[string]interface{}{
			"status": "completed", "state_version": 3, "result_json": datatypes.JSON(resultJSON),
			"result_hash": hex.EncodeToString(hash[:]), "completed_at": time.Now(),
		})
	if result.Error != nil {
		return result.Error
	}
	if result.RowsAffected == 0 {
		var call models.AIToolCall
		if err := r.db.WithContext(ctx).First(&call, "call_id = ?", callID).Error; err != nil {
			return err
		}
		if call.Status == "completed" {
			return nil
		}
		return errors.New("tool_state_conflict")
	}
	return nil
}

func validateToolWait(wait ToolWait) error {
	switch wait.State {
	case models.AIRunStateWaitingDevice, models.AIRunStateWaitingUserConsent, models.AIRunStateWaitingEdu:
	default:
		return errors.New("tool_result_invalid")
	}
	if strings.TrimSpace(wait.EventType) == "" || len(wait.EventType) > 48 || len(wait.ResumeKey) > 100 {
		return errors.New("tool_result_invalid")
	}
	if wait.State == models.AIRunStateWaitingUserConsent && !wait.ConsentScope.Valid() {
		return errors.New("tool_result_invalid")
	}
	if wait.Payload == nil {
		wait.Payload = make(map[string]interface{})
	}
	encoded, err := json.Marshal(wait.Payload)
	if err != nil || len(encoded) > 8<<10 {
		return errors.New("tool_result_invalid")
	}
	return nil
}

// containsForbiddenToolIdentity 拒绝模型通过任意嵌套参数指定身份。
// 工具执行身份只能由 Runtime 从认证后的 Run 注入。
func containsForbiddenToolIdentity(raw json.RawMessage) bool {
	var value interface{}
	if json.Unmarshal(raw, &value) != nil {
		return true
	}
	return containsForbiddenToolIdentityValue(value)
}

func containsForbiddenToolIdentityValue(value interface{}) bool {
	switch typed := value.(type) {
	case map[string]interface{}:
		for key, child := range typed {
			if strings.EqualFold(strings.TrimSpace(key), "user_id") {
				return true
			}
			if containsForbiddenToolIdentityValue(child) {
				return true
			}
		}
	case []interface{}:
		for _, child := range typed {
			if containsForbiddenToolIdentityValue(child) {
				return true
			}
		}
	}
	return false
}
