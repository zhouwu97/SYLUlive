package ai

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
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
	return result
}

// Execute 以 call_id 幂等执行纯读工具。userID 只能由 JWT Context 调用方注入。
func (r *ToolRegistry) Execute(ctx context.Context, callID, runID string, userID uint, toolName string, arguments json.RawMessage) (json.RawMessage, bool, error) {
	tool, ok := r.tools[toolName]
	if !ok {
		return nil, false, errors.New("tool_not_allowed")
	}
	if callID == "" || runID == "" || userID == 0 || len(arguments) == 0 || len(arguments) > 16<<10 {
		return nil, false, errors.New("invalid_tool_call")
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
			return nil, false, err
		}
		if existing.RunID != runID || existing.UserID != userID || existing.ToolName != toolName || existing.ArgumentsHash != hashText {
			return nil, false, errors.New("tool_call_idempotency_conflict")
		}
		if existing.Status == "completed" {
			return json.RawMessage(existing.ResultJSON), true, nil
		}
		return nil, true, errors.New("tool_call_in_progress")
	}
	result := r.db.WithContext(ctx).Model(&models.AIToolCall{}).
		Where("call_id = ? AND status = ? AND state_version = ?", callID, "pending", 0).
		Updates(map[string]interface{}{"status": "running", "state_version": 1})
	if result.Error != nil || result.RowsAffected != 1 {
		return nil, false, errors.New("tool_state_conflict")
	}

	value, executeErr := tool.Execute(ctx, userID, arguments)
	if executeErr != nil {
		now := time.Now()
		_ = r.db.WithContext(ctx).Model(&models.AIToolCall{}).
			Where("call_id = ? AND status = ? AND state_version = ?", callID, "running", 1).
			Updates(map[string]interface{}{"status": "failed", "state_version": 2, "completed_at": now}).Error
		return nil, false, executeErr
	}
	encoded, err := json.Marshal(value)
	if err != nil || len(encoded) > 256<<10 {
		return nil, false, errors.New("tool_result_invalid")
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
		return nil, false, errors.New("tool_state_conflict")
	}
	return encoded, false, nil
}
