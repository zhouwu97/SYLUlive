package handlers

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"

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

	// ToolRegistry 已按 call_id 做一次幂等；这里再用规范化参数生成稳定键，
	// 处理模型重连后重新生成 call_id 的情况。
	canonical, err := json.Marshal(input)
	if err != nil {
		return nil, errors.New("invalid_calendar_action")
	}
	digest := sha256.Sum256(canonical)
	idempotencyKey := "campus-agent-" + hex.EncodeToString(digest[:])
	draft, _, err := t.handler.CreateCalendarActionDraftForAgent(ctx, userID, input, idempotencyKey)
	if err != nil {
		return nil, err
	}
	return draft, nil
}
