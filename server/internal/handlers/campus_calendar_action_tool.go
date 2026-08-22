package handlers

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"strings"

	"shenliyuan/internal/ai"
	"shenliyuan/internal/models"
)

// campusCalendarActionProposalTool 是校园 Agent 唯一允许接触日历写链路的
// Tool。它只创建 waiting_confirmation 草稿，不直接写入事件、提醒或删除记录。
type campusCalendarActionProposalTool struct {
	handler *UserCalendarHandler
}

// NewCampusCalendarActionProposalTool 暴露 proposal-only 的 Agent Tool。
func NewCampusCalendarActionProposalTool(handler *UserCalendarHandler) ai.PureReadTool {
	return &campusCalendarActionProposalTool{handler: handler}
}

func (t *campusCalendarActionProposalTool) Name() string    { return "calendar.propose_action" }
func (t *campusCalendarActionProposalTool) Version() string { return "2026-08-22" }

func (t *campusCalendarActionProposalTool) Definition() ai.ToolDefinition {
	return ai.ToolDefinition{
		Name:        t.Name(),
		Description: "为当前用户创建待确认的个人日历操作草稿；只提案，不执行写入。",
		Parameters: map[string]interface{}{
			"type": "object",
			"properties": map[string]interface{}{
				"action_type": map[string]interface{}{
					"type": "string",
					"enum": []string{
						models.UserCalendarActionCreate,
						models.UserCalendarActionUpdate,
						models.UserCalendarActionDelete,
						models.UserCalendarActionReminderCreate,
					},
				},
				"event_id":                map[string]interface{}{"type": "integer", "minimum": 1},
				"title":                   map[string]interface{}{"type": "string", "maxLength": 160},
				"description":             map[string]interface{}{"type": "string", "maxLength": 4000},
				"start_at":                map[string]interface{}{"type": "string", "format": "date-time"},
				"end_at":                  map[string]interface{}{"type": "string", "format": "date-time"},
				"all_day":                 map[string]interface{}{"type": "boolean"},
				"location":                map[string]interface{}{"type": "string", "maxLength": 200},
				"timezone":                map[string]interface{}{"type": "string", "maxLength": 64},
				"reminder_minutes_before": map[string]interface{}{"type": "integer", "minimum": 0, "maximum": 10080},
			},
			"required":             []string{"action_type"},
			"additionalProperties": false,
		},
	}
}

func (t *campusCalendarActionProposalTool) Execute(
	ctx context.Context,
	userID uint,
	arguments json.RawMessage,
) (interface{}, error) {
	if t == nil || t.handler == nil || userID == 0 {
		return nil, errors.New("calendar_action_unavailable")
	}
	var input CalendarActionDraftRequest
	decoder := json.NewDecoder(bytes.NewReader(arguments))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&input); err != nil {
		return nil, errors.New("invalid_calendar_action")
	}
	if input.ActionType == "" {
		return nil, errors.New("invalid_calendar_action")
	}

	// ToolRegistry 已按 call_id 做一次幂等；Draft 还需要按 Run 隔离，
	// 避免用户在新 Run 中重新提出相同操作时复用旧的 cancelled/expired Draft。
	canonical, err := json.Marshal(input)
	if err != nil {
		return nil, errors.New("invalid_calendar_action")
	}
	digest := sha256.Sum256(canonical)
	runID := strings.TrimSpace(ai.ToolCallRunID(ctx))
	if runID == "" {
		// 直接调用（例如单元测试）没有 ToolRegistry 上下文，保留稳定的本地作用域。
		runID = "direct"
	}
	if len(runID) > 36 {
		runDigest := sha256.Sum256([]byte(runID))
		runID = hex.EncodeToString(runDigest[:])[:24]
	}
	payloadHash := hex.EncodeToString(digest[:])[:48]
	idempotencyKey := "campus-agent-" + runID + "-" + payloadHash
	draft, _, err := t.handler.CreateCalendarActionDraftForAgent(ctx, userID, input, idempotencyKey)
	if err != nil {
		return nil, err
	}
	return draft, nil
}
