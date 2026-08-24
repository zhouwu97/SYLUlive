package ai

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"

	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

// AgentContextEnvelope 是客户端传入的最小上下文引用。它不是业务事实副本，
// 每次创建 Run 时都必须通过当前用户权限和最新数据库状态重新校验。
type AgentContextEnvelope struct {
	Entrypoint      string            `json:"entrypoint"`
	ContextRefs     []AgentContextRef `json:"context_refs"`
	SuggestedIntent string            `json:"suggested_intent,omitempty"`
}

type AgentContextRef struct {
	Type string `json:"type"`
	ID   string `json:"id"`
}

func (r *Runtime) validateAgentContext(
	ctx context.Context,
	userID uint,
	input *AgentContextEnvelope,
) (*AgentContextEnvelope, error) {
	if input == nil {
		return nil, nil
	}
	entrypoint := strings.TrimSpace(input.Entrypoint)
	if entrypoint == "" || len([]rune(entrypoint)) > 64 {
		return nil, runtimeContextError("entrypoint 无效")
	}
	if len(input.ContextRefs) > 4 {
		return nil, runtimeContextError("上下文引用数量过多")
	}
	if len([]rune(input.SuggestedIntent)) > 160 {
		return nil, runtimeContextError("suggested_intent 过长")
	}

	refs := make([]AgentContextRef, 0, len(input.ContextRefs))
	for _, raw := range input.ContextRefs {
		refType := strings.TrimSpace(raw.Type)
		refID := strings.TrimSpace(raw.ID)
		if refType == "" || refID == "" || len([]rune(refID)) > 100 {
			return nil, runtimeContextError("上下文引用无效")
		}
		switch refType {
		case "competition_event":
			eventID, err := strconv.ParseUint(refID, 10, 64)
			if err != nil || eventID == 0 {
				return nil, runtimeContextError("赛事上下文 ID 无效")
			}
			var event models.CompetitionEvent
			if err := r.db.WithContext(ctx).
				Where("id = ? AND status IN ? AND deleted_at IS NULL", eventID, []string{"active", "published"}).
				First(&event).Error; err != nil {
				if err == gorm.ErrRecordNotFound {
					return nil, runtimeContextError("赛事上下文已不存在或不可见")
				}
				return nil, err
			}
		case "date":
			if len(refID) != 10 || refID[4] != '-' || refID[7] != '-' {
				return nil, runtimeContextError("日期上下文 ID 无效")
			}
		case "canteen", "canteen_dish", "academic_term", "announcement":
			// 这些引用类型先做格式边界校验；对应领域服务在后续读取时
			// 仍需按用户权限重新查找，不能把客户端对象当作事实源。
		default:
			return nil, runtimeContextError("不支持的上下文类型")
		}
		refs = append(refs, AgentContextRef{Type: refType, ID: refID})
	}
	return &AgentContextEnvelope{
		Entrypoint:      entrypoint,
		ContextRefs:     refs,
		SuggestedIntent: strings.TrimSpace(input.SuggestedIntent),
	}, nil
}

func runtimeContextError(message string) error {
	return &RuntimeError{Code: "invalid_agent_context", Message: message}
}

func (r *Runtime) agentContextPrompt(
	ctx context.Context,
	userID uint,
	raw []byte,
) string {
	envelope, ok := decodeAgentContext(raw)
	if !ok {
		return ""
	}
	var builder strings.Builder
	builder.WriteString("本轮页面上下文（服务端已校验，不能视为客户端事实副本）：\n")
	builder.WriteString("入口：" + sanitizeAttribute(envelope.Entrypoint) + "\n")
	if intent := strings.TrimSpace(envelope.SuggestedIntent); intent != "" {
		builder.WriteString("建议意图：" + sanitizeAttribute(intent) + "\n")
	}
	for _, ref := range envelope.ContextRefs {
		builder.WriteString(fmt.Sprintf("- %s id=%s", sanitizeAttribute(ref.Type), sanitizeAttribute(ref.ID)))
		if ref.Type == "competition_event" {
			var event models.CompetitionEvent
			if err := r.db.WithContext(ctx).
				Where("id = ? AND status IN ? AND deleted_at IS NULL", ref.ID, []string{"active", "published"}).
				Select("id", "title", "version").First(&event).Error; err == nil {
				builder.WriteString(" title=" + sanitizeAttribute(event.Title))
				builder.WriteString(fmt.Sprintf(" version=%d", event.Version))
			}
		}
		builder.WriteString("\n")
	}
	builder.WriteString("系统会在生成前先读取上述引用对应的应用内数据；必须先阅读预读取结果。若预读取失败或结果不完整，必须明确说明，不能根据客户端页面对象猜测。需要更细事实时才继续调用对应工具。")
	return builder.String()
}

func decodeAgentContext(raw []byte) (AgentContextEnvelope, bool) {
	if len(raw) == 0 || string(raw) == "{}" {
		return AgentContextEnvelope{}, false
	}
	var envelope AgentContextEnvelope
	if err := json.Unmarshal(raw, &envelope); err != nil || len(envelope.ContextRefs) == 0 {
		return AgentContextEnvelope{}, false
	}
	return envelope, true
}

type agentContextPreflightCall struct {
	name      string
	arguments json.RawMessage
}

// agentContextPreflight 在模型生成前读取页面引用对应的最新应用数据。
// 预读取只使用只读工具，结果沿用 ToolRegistry 的审计、幂等和权限边界。
func (r *Runtime) agentContextPreflight(ctx context.Context, run *models.AIRun) ([]Message, error) {
	envelope, ok := decodeAgentContext(run.AgentContext)
	if !ok {
		return nil, nil
	}
	if r.tools == nil {
		return nil, errors.New("agent_context_preflight_unavailable")
	}
	calls := agentContextPreflightCalls(envelope)
	if len(calls) == 0 {
		return nil, errors.New("agent_context_preflight_plan_empty")
	}

	messages := make([]Message, 0, len(calls)*2)
	completed := 0
	for index, call := range calls {
		if !r.tools.HasTool(call.name) {
			continue
		}
		callID := fmt.Sprintf("preflight-%s-%d", run.ID, index+1)
		_, _ = r.appendEvent(ctx, run.ID, "agent.activity", map[string]interface{}{
			"activity_code": "app_data_preflight",
			"text":          "正在先读取页面相关的应用内数据",
			"tool_name":     call.name,
		}, true)
		_, _ = r.appendEvent(ctx, run.ID, "tool.executing", map[string]interface{}{
			"call_id": callID, "tool_name": call.name, "preflight": true,
		}, true)

		var execution ToolExecutionResult
		var cached bool
		var executeErr error
		if gateErr := r.agentToolAllowed(run, call.name); gateErr != nil {
			executeErr = gateErr
		} else {
			execution, cached, executeErr = r.tools.Execute(
				ctx, callID, run.ID, run.UserID, call.name, call.arguments,
			)
		}
		success := executeErr == nil && execution.Wait == nil
		if executeErr != nil {
			execution.Result = toolExecutionFailure(executeErr)
		}
		if execution.Wait != nil {
			execution.Result = json.RawMessage(`{"status":"preflight_unavailable","warnings":["该应用数据需要交互授权，已跳过本轮预读取"]}`)
		}
		if len(execution.Result) == 0 {
			execution.Result = json.RawMessage(`{"status":"preflight_unavailable","warnings":["应用数据暂时不可用"]}`)
		}
		modelResult := toolResultForModel(call.name, execution.Result)
		messages = append(messages,
			Message{
				Role: "assistant",
				ToolCalls: []ToolCallMessage{{
					ID: callID, Type: "function",
					Function: ToolCallFunction{Name: call.name, Arguments: string(call.arguments)},
				}},
			},
			Message{Role: "tool", ToolCallID: callID, Content: string(modelResult)},
		)
		if success {
			completed++
		}
		_, _ = r.appendEvent(ctx, run.ID, "tool.completed", map[string]interface{}{
			"call_id": callID, "tool_name": call.name, "success": success,
			"cached": cached, "preflight": true,
		}, true)
		r.appendPersonalDataEvidence(ctx, run.ID, callID, execution.Result)
	}
	if completed == 0 {
		return nil, errors.New("agent_context_preflight_unavailable")
	}
	_, _ = r.appendEvent(ctx, run.ID, "agent.activity", map[string]interface{}{
		"activity_code": "app_data_preflight_completed",
		"text":          "已读取应用内数据，开始分析",
	}, true)
	return messages, nil
}

func agentContextPreflightCalls(envelope AgentContextEnvelope) []agentContextPreflightCall {
	calls := make([]agentContextPreflightCall, 0, len(envelope.ContextRefs)+1)
	seen := make(map[string]struct{})
	add := func(name string, arguments interface{}) {
		payload, err := json.Marshal(arguments)
		if err != nil {
			return
		}
		key := name + "\x00" + string(payload)
		if _, exists := seen[key]; exists {
			return
		}
		seen[key] = struct{}{}
		calls = append(calls, agentContextPreflightCall{name: name, arguments: payload})
	}
	for _, ref := range envelope.ContextRefs {
		switch ref.Type {
		case "competition_event":
			eventID, err := strconv.ParseUint(ref.ID, 10, 64)
			if err == nil && eventID > 0 {
				add("competition.get_details", map[string]interface{}{"event_id": eventID})
			}
			if envelope.Entrypoint == "competition_detail" {
				add("competition.get_my_plan", map[string]interface{}{"limit": 20})
			}
		case "date":
			add("calendar.get_day", map[string]interface{}{"date": ref.ID})
			if envelope.Entrypoint == "calendar" {
				add("personal_calendar.get_day", map[string]interface{}{"date": ref.ID})
			}
		}
	}
	return calls
}
