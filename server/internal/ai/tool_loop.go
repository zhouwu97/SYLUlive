package ai

import (
	"context"
	"encoding/json"
	"strings"

	"shenliyuan/internal/models"
)

const (
	maxToolRounds       = 4
	maxToolsPerRound    = 3
	maxToolArgumentSize = 16 << 10
)

// toolLoopOutcome 汇总一次 Run 的多轮模型调用，避免把中间工具回合当作最终回答输出。
type toolLoopOutcome struct {
	answer      string
	usage       ProviderEvent
	generated   bool
	toolUsed    bool
	cancelled   bool
	failureCode string
	pause       *toolLoopPause
}

type collectedToolCall struct {
	id        string
	name      string
	arguments strings.Builder
}

type pendingToolWait struct {
	CallID string
	Name   string
	Wait   ToolWait
}

// toolLoopPause 是写入恢复表前的内存快照；其中不保存原始设备缓存或凭据。
type toolLoopPause struct {
	State    string
	Messages []Message
	Pending  []pendingToolWait
}

// executeToolLoop 执行受限的模型-工具循环。工具身份始终由 run.UserID 注入，
// 模型只可提交声明中的参数，且每轮工具数量与总轮数均有硬限制。
func (r *Runtime) executeToolLoop(ctx context.Context, run *models.AIRun, messages []Message, definitions []ToolDefinition) toolLoopOutcome {
	outcome := toolLoopOutcome{}
	toolRounds := 0

	for {
		stream, err := r.provider.Start(ctx, ProviderRequest{
			Messages: messages, Temperature: 0.1, MaxTokens: 800, Tools: definitions,
		})
		if err != nil {
			if r.runIsCancelled(run.ID) {
				outcome.cancelled = true
				return outcome
			}
			outcome.failureCode = providerErrorClass(err)
			return outcome
		}

		answer, calls, roundOutcome := r.collectProviderRound(ctx, run, stream, outcome.usage)
		_ = stream.Close()
		outcome.usage = roundOutcome.usage
		outcome.generated = outcome.generated || roundOutcome.generated
		if roundOutcome.cancelled || roundOutcome.failureCode != "" {
			return toolLoopOutcome{
				usage:       outcome.usage,
				generated:   outcome.generated,
				cancelled:   roundOutcome.cancelled,
				failureCode: roundOutcome.failureCode,
			}
		}

		if len(calls) == 0 {
			if strings.TrimSpace(answer) == "" {
				outcome.failureCode = ProviderErrorInvalid
				return outcome
			}
			if run.State == models.AIRunStatePlanning {
				if err := r.transition(ctx, run, models.AIRunStatePlanning, models.AIRunStateGenerating); err != nil {
					outcome.failureCode = "tool_loop_state_conflict"
					return outcome
				}
			}
			outcome.answer = answer
			return outcome
		}

		toolRounds++
		if toolRounds > maxToolRounds {
			outcome.failureCode = "tool_loop_limit"
			return outcome
		}
		outcome.toolUsed = true
		if run.State != models.AIRunStateToolRequested {
			outcome.failureCode = "tool_loop_state_conflict"
			return outcome
		}
		if err := r.transition(ctx, run, models.AIRunStateToolRequested, models.AIRunStateToolExecuting); err != nil {
			outcome.failureCode = "tool_loop_state_conflict"
			return outcome
		}

		assistantCallMessages := make([]ToolCallMessage, 0, len(calls))
		toolResultMessages := make([]Message, 0, len(calls))
		pendingWaits := make([]pendingToolWait, 0, len(calls))
		for _, call := range calls {
			arguments := call.arguments.String()
			assistantCallMessages = append(assistantCallMessages, ToolCallMessage{
				ID: call.id, Type: "function", Function: ToolCallFunction{Name: call.name, Arguments: arguments},
			})
			_, _ = r.appendEvent(ctx, run.ID, "tool.executing", map[string]interface{}{
				"call_id": call.id, "tool_name": call.name,
			}, true)

			execution, cached, executeErr := r.tools.Execute(ctx, call.id, run.ID, run.UserID, call.name, json.RawMessage(arguments))
			success := executeErr == nil
			if executeErr != nil {
				execution.Result = toolExecutionFailure(executeErr)
			}
			if execution.Wait != nil {
				pendingWaits = append(pendingWaits, pendingToolWait{CallID: call.id, Name: call.name, Wait: *execution.Wait})
				continue
			}
			toolResultMessages = append(toolResultMessages, Message{Role: "tool", ToolCallID: call.id, Content: string(execution.Result)})
			_, _ = r.appendEvent(ctx, run.ID, "tool.completed", map[string]interface{}{
				"call_id": call.id, "tool_name": call.name, "success": success, "cached": cached,
			}, true)
		}
		messages = append(messages, Message{Role: "assistant", Content: answer, ToolCalls: assistantCallMessages})
		messages = append(messages, toolResultMessages...)
		if len(pendingWaits) > 0 {
			state := pendingWaits[0].Wait.State
			for _, pending := range pendingWaits[1:] {
				if pending.Wait.State != state {
					outcome.failureCode = "tool_loop_mixed_wait_state"
					return outcome
				}
			}
			outcome.pause = &toolLoopPause{State: state, Messages: messages, Pending: pendingWaits}
			return outcome
		}

		if err := r.transition(ctx, run, models.AIRunStateToolExecuting, models.AIRunStateToolCompleted); err != nil {
			outcome.failureCode = "tool_loop_state_conflict"
			return outcome
		}
		if err := r.transition(ctx, run, models.AIRunStateToolCompleted, models.AIRunStatePlanning); err != nil {
			outcome.failureCode = "tool_loop_state_conflict"
			return outcome
		}
	}
}

// collectProviderRound 收集流式参数片段，在模型完成本轮后再执行工具。
func (r *Runtime) collectProviderRound(ctx context.Context, run *models.AIRun, stream ProviderStream, initialUsage ProviderEvent) (string, []collectedToolCall, toolLoopOutcome) {
	outcome := toolLoopOutcome{usage: initialUsage}
	answer := strings.Builder{}
	calls := make([]collectedToolCall, 0, maxToolsPerRound)
	byID := make(map[string]int, maxToolsPerRound)

	for {
		event, err := stream.Next(ctx)
		if err != nil {
			if r.runIsCancelled(run.ID) {
				outcome.cancelled = true
			} else {
				outcome.failureCode = providerErrorClass(err)
			}
			return "", nil, outcome
		}
		switch event.Type {
		case ProviderEventTextDelta:
			answer.WriteString(event.Text)
			outcome.generated = outcome.generated || strings.TrimSpace(event.Text) != ""
		case ProviderEventUsage:
			outcome.usage.InputTokens += event.InputTokens
			outcome.usage.OutputTokens += event.OutputTokens
			outcome.usage.CacheHitTokens += event.CacheHitTokens
		case ProviderEventToolCallStarted:
			outcome.generated = true
			if event.CallID == "" || event.ToolName == "" || len(calls) >= maxToolsPerRound {
				outcome.failureCode = "tool_call_limit"
				return "", nil, outcome
			}
			if _, duplicated := byID[event.CallID]; duplicated {
				outcome.failureCode = "invalid_tool_call"
				return "", nil, outcome
			}
			if run.State != models.AIRunStateToolRequested {
				if err := r.transition(ctx, run, models.AIRunStatePlanning, models.AIRunStateToolRequested); err != nil {
					outcome.failureCode = "tool_loop_state_conflict"
					return "", nil, outcome
				}
			}
			byID[event.CallID] = len(calls)
			calls = append(calls, collectedToolCall{id: event.CallID, name: event.ToolName})
			_, _ = r.appendEvent(ctx, run.ID, "tool.requested", map[string]interface{}{
				"call_id": event.CallID, "tool_name": event.ToolName,
			}, true)
		case ProviderEventToolArgumentsDelta:
			callIndex, found := byID[event.CallID]
			if !found || event.ToolName == "" || calls[callIndex].name != event.ToolName {
				outcome.failureCode = "invalid_tool_call"
				return "", nil, outcome
			}
			if calls[callIndex].arguments.Len()+len(event.ArgumentsDelta) > maxToolArgumentSize {
				outcome.failureCode = "invalid_tool_call"
				return "", nil, outcome
			}
			calls[callIndex].arguments.WriteString(event.ArgumentsDelta)
		case ProviderEventToolCallCompleted:
			// 参数由 arguments_delta 完整累积；该事件仅用于兼容不带载荷的 Provider。
		case ProviderEventCompleted:
			return answer.String(), calls, outcome
		}
	}
}

// toolExecutionFailure 向模型返回稳定、最小的错误代码，避免暴露数据库或实现细节。
func toolExecutionFailure(err error) json.RawMessage {
	code := "tool_execution_failed"
	switch err.Error() {
	case "tool_not_allowed", "invalid_tool_call", "tool_call_idempotency_conflict", "tool_call_in_progress", "tool_state_conflict", "tool_result_invalid":
		code = err.Error()
	}
	return json.RawMessage(`{"status":"failed","error_code":"` + code + `"}`)
}
