package ai

import (
	"context"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"time"

	"shenliyuan/internal/academic"
	"shenliyuan/internal/models"
)

const (
	maxToolsPerRound    = 3
	maxToolArgumentSize = 16 << 10
)

// toolLoopOutcome 汇总一次 Run 的多轮模型调用，避免把中间工具回合当作最终回答输出。
type toolLoopOutcome struct {
	answer           string
	citationFallback string
	academicFallback string
	academicRiskSeen bool
	usage            ProviderEvent
	generated        bool
	toolUsed         bool
	cancelled        bool
	failureCode      string
	pause            *toolLoopPause
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

type personalDataEvidenceEvent struct {
	Source        string                 `json:"source"`
	Dataset       string                 `json:"dataset,omitempty"`
	Title         string                 `json:"title,omitempty"`
	FetchedAt     *time.Time             `json:"fetched_at,omitempty"`
	ExpiresAt     *time.Time             `json:"expires_at,omitempty"`
	IsStale       bool                   `json:"is_stale"`
	AnalysisInput map[string]interface{} `json:"analysis_input,omitempty"`
}

func contextResultsEvidence(results ...academic.ContextResult) []personalDataEvidenceEvent {
	items := make([]personalDataEvidenceEvent, 0, len(results))
	for _, result := range results {
		for _, evidence := range result.Evidence {
			items = append(items, personalDataEvidenceEvent{
				Source: string(evidence.Source), Dataset: string(evidence.Dataset),
				FetchedAt: evidence.FetchedAt, ExpiresAt: evidence.ExpiresAt, IsStale: evidence.IsStale,
			})
		}
		if len(result.Evidence) == 0 && result.Source.Valid() {
			items = append(items, personalDataEvidenceEvent{
				Source: string(result.Source), FetchedAt: result.FetchedAt,
				ExpiresAt: result.ExpiresAt, IsStale: result.IsStale,
			})
		}
	}
	return items
}

// executeToolLoop 执行受限的模型-工具循环。工具身份始终由 run.UserID 注入，
// 模型只可提交声明中的参数，且每轮工具数量与总轮数均有硬限制。
func (r *Runtime) executeToolLoop(ctx context.Context, run *models.AIRun, messages []Message, definitions []ToolDefinition, requiredTool string, requiredToolAlreadyCompleted bool) toolLoopOutcome {
	outcome := toolLoopOutcome{}
	toolRounds := 0
	requiredToolCompleted := requiredTool == "" || requiredToolAlreadyCompleted

	for {
		requestTools := definitions
		if toolRounds >= r.config.MaxToolSteps {
			// 工具轮数耗尽后仍允许模型基于已有结果作答，但不再暴露任何工具。
			requestTools = nil
		}
		forcedTool := ""
		if !requiredToolCompleted {
			forcedTool = requiredTool
		}
		stream, err := r.provider.Start(ctx, ProviderRequest{
			Messages: messages, Temperature: 0.1, MaxTokens: r.config.MaxOutputTokens,
			Tools: requestTools, RequiredTool: forcedTool,
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
			if !requiredToolCompleted {
				outcome.failureCode = "required_tool_not_used"
				return outcome
			}
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
		if toolRounds > r.config.MaxToolSteps {
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
			if !requiredToolCompleted && call.name != requiredTool {
				outcome.failureCode = "required_tool_not_used"
				return outcome
			}
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
				_, _ = r.appendEvent(ctx, run.ID, "plan.revised", map[string]interface{}{
					"reason": "tool_execution_failed", "tool_name": call.name,
				}, true)
			}
			if execution.Wait != nil {
				pendingWaits = append(pendingWaits, pendingToolWait{CallID: call.id, Name: call.name, Wait: *execution.Wait})
				continue
			}
			if failureCode := fatalToolResultCode(call.name, execution.Result); failureCode != "" {
				outcome.failureCode = failureCode
				return outcome
			}
			if call.name == requiredTool && success {
				requiredToolCompleted = true
			}
			modelResult := toolResultForModel(call.name, execution.Result)
			if fallback, riskSeen := academicRiskFallback(call.name, execution.Result); fallback != "" {
				outcome.academicFallback = fallback
				outcome.academicRiskSeen = riskSeen
			}
			if fallback := academicCitationFallback(call.name, execution.Result); fallback != "" {
				outcome.citationFallback = fallback
			}
			toolResultMessages = append(toolResultMessages, Message{Role: "tool", ToolCallID: call.id, Content: string(modelResult)})
			eventPayload := map[string]interface{}{
				"call_id": call.id, "tool_name": call.name, "success": success, "cached": cached,
			}
			if call.name == "calendar.propose_action" && success {
				var actionDraft map[string]interface{}
				if json.Unmarshal(execution.Result, &actionDraft) == nil && actionDraft["id"] != nil {
					eventPayload["action_draft"] = actionDraft
					_, _ = r.appendEvent(ctx, run.ID, "approval.required", map[string]interface{}{
						"activity_code": "action_confirmation",
						"text":          "已生成待确认的操作安排",
						"action_draft":  actionDraft,
					}, true)
				}
			}
			_, _ = r.appendEvent(ctx, run.ID, "tool.completed", eventPayload, true)
			r.appendPersonalDataEvidence(ctx, run.ID, call.id, execution.Result)
		}
		messages = append(messages, Message{Role: "assistant", Content: answer, ToolCalls: assistantCallMessages})
		messages = append(messages, toolResultMessages...)
		if len(pendingWaits) > 0 {
			state := pendingWaits[0].Wait.State
			consentScope := pendingWaits[0].Wait.ConsentScope
			for _, pending := range pendingWaits[1:] {
				if pending.Wait.State != state {
					outcome.failureCode = "tool_loop_mixed_wait_state"
					return outcome
				}
				if state == models.AIRunStateWaitingUserConsent && pending.Wait.ConsentScope != consentScope {
					outcome.failureCode = "tool_loop_mixed_consent_scope"
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

func academicCitationFallback(toolName string, result json.RawMessage) string {
	if toolName != "hy3_decision.analyze_academic" && toolName != "hy3_decision_analyze_academic" {
		return ""
	}
	var envelope struct {
		Status        string                 `json:"status"`
		AnalysisInput map[string]interface{} `json:"analysis_input"`
		IsStale       bool                   `json:"is_stale"`
	}
	if json.Unmarshal(result, &envelope) != nil || envelope.Status != "ok" {
		return ""
	}
	input := sanitizeAcademicAnalysisInput(envelope.AnalysisInput)
	rawCourses, ok := input["courses"].([]map[string]interface{})
	if !ok || len(rawCourses) == 0 {
		return ""
	}
	failed := make([]string, 0)
	for _, course := range rawCourses {
		passed, known := course["passed"].(bool)
		if !known || passed {
			continue
		}
		name, _ := course["course_name"].(string)
		if name == "" {
			continue
		}
		detail := "《" + name + "》"
		if grade, exists := course["grade"]; exists {
			detail += "成绩 " + formatAcademicNumber(grade)
		}
		if credits, exists := course["credits"]; exists {
			detail += "、" + formatAcademicNumber(credits) + " 学分"
		}
		failed = append(failed, detail)
	}
	var builder strings.Builder
	builder.WriteString("已成功读取你的个人成绩。")
	if len(failed) == 0 {
		builder.WriteString("本次成绩快照中没有标记为未通过的课程。")
	} else {
		builder.WriteString("本次可以确认未通过课程为：")
		builder.WriteString(strings.Join(failed, "；"))
		builder.WriteString("。")
	}
	if earned, earnedOK := input["earned_credits"]; earnedOK {
		builder.WriteString("当前已获得学分为 " + formatAcademicNumber(earned))
		if required, requiredOK := input["required_credits"]; requiredOK {
			builder.WriteString(" / " + formatAcademicNumber(required))
		}
		builder.WriteString("。")
	}
	if envelope.IsStale {
		builder.WriteString("这份成绩快照已过期，最新变动请先刷新教务数据后再核对。")
	}
	builder.WriteString("本次校规引用未通过校验，因此不展开补考、二次考试或重修的校内流程；个人成绩结论不受影响。")
	return builder.String()
}

// academicRiskFallback 是模型输出的最后一道事实护栏：当模型把明确的挂科或
// 数据缺口说成“风险不大”，直接使用工具基于同一份快照生成的边界化回答。
func academicRiskFallback(toolName string, result json.RawMessage) (string, bool) {
	if !isAcademicRiskToolName(toolName) || !json.Valid(result) {
		return "", false
	}
	var envelope struct {
		Status   string                 `json:"status"`
		Data     map[string]interface{} `json:"data"`
		Warnings []string               `json:"warnings"`
	}
	if json.Unmarshal(result, &envelope) != nil || envelope.Status == "" || envelope.Status == "failed" {
		return "", false
	}
	data := envelope.Data
	if len(data) == 0 {
		return "", false
	}
	risks := stringList(data["risks"])
	actions := stringList(data["actions"])
	confirmations := stringList(data["to_confirm"])
	riskLevel, _ := data["risk_level"].(string)
	riskSeen := riskLevel != "no_observed_risk" || len(risks) > 0
	var builder strings.Builder
	builder.WriteString("基于当前已授权快照，能确认的范围如下：\n")
	if grades, ok := data["grades"].(map[string]interface{}); ok {
		courseCount, courseCountOK := jsonNumber(grades["course_count"])
		totalCredits, totalCreditsOK := jsonNumber(grades["total_credits"])
		weightedGPA, weightedGPAOK := jsonNumber(grades["weighted_gpa"])
		if courseCountOK || totalCreditsOK || weightedGPAOK {
			builder.WriteString("成绩事实：")
			if courseCountOK {
				builder.WriteString(formatAcademicNumber(courseCount) + " 门课程")
			}
			if totalCreditsOK {
				builder.WriteString("，累计 " + formatAcademicNumber(totalCredits) + " 学分")
			}
			if weightedGPAOK {
				builder.WriteString("，加权 GPA " + formatAcademicNumber(weightedGPA))
			}
			builder.WriteString("。\n")
		}
		if terms, ok := grades["covered_terms"].([]interface{}); ok && len(terms) > 0 {
			labels := make([]string, 0, len(terms))
			for _, rawTerm := range terms {
				if label, ok := rawTerm.(string); ok && strings.TrimSpace(label) != "" {
					labels = append(labels, strings.TrimSpace(label))
				}
			}
			if len(labels) > 0 {
				builder.WriteString("覆盖学期：" + strings.Join(labels, "、") + "。\n")
			}
		}
	}
	if len(risks) > 0 {
		builder.WriteString("主要风险：\n")
		for _, risk := range risks {
			builder.WriteString("- ")
			builder.WriteString(risk)
			builder.WriteByte('\n')
		}
	} else {
		builder.WriteString("当前可见数据没有发现明确的未通过课程或已计算学分缺口。\n")
	}
	if len(actions) > 0 {
		builder.WriteString("建议优先做：\n")
		for _, action := range actions {
			builder.WriteString("- ")
			builder.WriteString(action)
			builder.WriteByte('\n')
		}
	}
	if len(confirmations) > 0 || len(envelope.Warnings) > 0 {
		builder.WriteString("仍需确认：\n")
		for _, item := range append(confirmations, envelope.Warnings...) {
			item = strings.TrimSpace(item)
			if item == "" {
				continue
			}
			builder.WriteString("- ")
			builder.WriteString(item)
			builder.WriteByte('\n')
		}
	}
	return strings.TrimSpace(builder.String()), riskSeen
}

func isAcademicRiskToolName(toolName string) bool {
	return toolName == "academic_get_risk_analysis" || toolName == "academic.get_risk_analysis"
}

func stringList(value interface{}) []string {
	items, ok := value.([]interface{})
	if !ok {
		return nil
	}
	result := make([]string, 0, len(items))
	for _, item := range items {
		if text, ok := item.(string); ok && strings.TrimSpace(text) != "" {
			result = append(result, strings.TrimSpace(text))
		}
	}
	return result
}

func academicAnswerNeedsGuard(answer, fallback string, riskSeen bool) bool {
	if strings.TrimSpace(fallback) == "" {
		return false
	}
	normalized := strings.ToLower(strings.TrimSpace(answer))
	if !riskSeen {
		return false
	}
	if containsAny(normalized,
		"总体风险不大", "风险不大", "没有风险", "无明显风险", "风险很小",
		"没有观察到挂科风险", "未观察到挂科风险", "未发现挂科风险", "没有挂科风险",
		"没有不及格", "未出现不及格", "未发现不及格", "没有挂科", "未出现挂科",
	) {
		return true
	}
	return !containsAny(normalized, "未通过", "挂科", "学分缺口", "成绩缺失", "数据覆盖", "风险")
}

func academicRiskFinalAnswer(answer, fallback string, riskSeen bool) string {
	if riskSeen && strings.TrimSpace(fallback) != "" {
		return fallback
	}
	if academicAnswerNeedsGuard(answer, fallback, riskSeen) {
		return fallback
	}
	return answer
}

func formatAcademicNumber(value interface{}) string {
	number, ok := value.(float64)
	if !ok {
		return strings.TrimSpace(fmt.Sprint(value))
	}
	return strconv.FormatFloat(number, 'f', -1, 64)
}

// toolResultForModel 保留数据库中的原始工具审计结果，但不把 Hy3 的自由叙事和内部字段名
// 传给最终模型。个人学业结论只使用本地校验过的确定性字段和分析输入。
func toolResultForModel(toolName string, result json.RawMessage) json.RawMessage {
	if toolName != "hy3_decision.analyze_academic" && toolName != "hy3_decision_analyze_academic" {
		return result
	}
	var envelope struct {
		Status                string                 `json:"status"`
		DeterministicFindings map[string]interface{} `json:"deterministic_findings"`
		AnalysisInput         map[string]interface{} `json:"analysis_input"`
		Warnings              []string               `json:"warnings"`
	}
	if json.Unmarshal(result, &envelope) != nil || envelope.Status != "ok" {
		return result
	}
	findings := envelope.DeterministicFindings
	localizedFindings := map[string]interface{}{
		"未通过课程数":      findings["failed_course_count"],
		"未通过必修课程涉及学分": findings["failed_required_credits"],
		"已获得学分":       findings["earned_credits"],
		"总学分缺口":       findings["credit_gap"],
		"二课学分缺口":      findings["erke_gap"],
		"成绩未知课程数":     findings["unknown_grade_course_count"],
		"学分未知课程数":     findings["missing_credit_course_count"],
		"数据完整度百分比":    findings["data_completeness_percent"],
		"未通过课程":       findings["failed_courses"],
	}
	input := sanitizeAcademicAnalysisInput(envelope.AnalysisInput)
	localizedInput := map[string]interface{}{
		"已获得学分":   input["earned_credits"],
		"要求学分":    input["required_credits"],
		"已获得二课学分": input["erke_earned"],
		"要求二课学分":  input["erke_required"],
	}
	if rawCourses, ok := input["courses"].([]map[string]interface{}); ok {
		courses := make([]map[string]interface{}, 0, len(rawCourses))
		for _, course := range rawCourses {
			item := map[string]interface{}{
				"课程名称": course["course_name"],
				"成绩":   course["grade"],
				"学分":   course["credits"],
			}
			if required, ok := course["is_required"].(bool); ok {
				if required {
					item["课程性质"] = "必修"
				} else {
					item["课程性质"] = "选修"
				}
			}
			if passed, ok := course["passed"].(bool); ok {
				if passed {
					item["状态"] = "已通过"
				} else {
					item["状态"] = "未通过"
				}
			}
			courses = append(courses, item)
		}
		localizedInput["课程"] = courses
	}
	payload, err := json.Marshal(map[string]interface{}{
		"status": "ok", "学业结论": localizedFindings,
		"分析依据": localizedInput, "warnings": envelope.Warnings,
	})
	if err != nil {
		return json.RawMessage(`{"status":"unavailable","warnings":["学业分析结果整理失败"]}`)
	}
	return payload
}

// appendPersonalDataEvidence 只推送个人数据的来源元数据，绝不把工具结果正文写入 SSE。
// 这样客户端可展示来源、更新时间与过期状态，同时不会把成绩或设备缓存扩散到事件流。
func (r *Runtime) appendPersonalDataEvidence(ctx context.Context, runID, callID string, result json.RawMessage) {
	evidence := extractPersonalDataEvidence(result)
	if len(evidence) == 0 {
		return
	}
	_, _ = r.appendEvent(ctx, runID, "personal_data.evidence", map[string]interface{}{
		"call_id": callID, "evidence": evidence,
	}, true)
}

func extractPersonalDataEvidence(result json.RawMessage) []personalDataEvidenceEvent {
	if !json.Valid(result) {
		return nil
	}
	var envelope struct {
		Source        string                      `json:"source"`
		Dataset       string                      `json:"dataset"`
		FetchedAt     *time.Time                  `json:"fetched_at"`
		ExpiresAt     *time.Time                  `json:"expires_at"`
		IsStale       bool                        `json:"is_stale"`
		Evidence      []personalDataEvidenceEvent `json:"evidence"`
		AnalysisInput map[string]interface{}      `json:"analysis_input"`
	}
	if json.Unmarshal(result, &envelope) != nil {
		return nil
	}
	items := make([]personalDataEvidenceEvent, 0, len(envelope.Evidence)+1)
	items = append(items, envelope.Evidence...)
	if analysisInput := sanitizeAcademicAnalysisInput(envelope.AnalysisInput); len(analysisInput) > 0 {
		items = append(items, personalDataEvidenceEvent{
			Source: "hy3_mcp", Dataset: "academic_analysis", FetchedAt: envelope.FetchedAt,
			ExpiresAt: envelope.ExpiresAt, IsStale: envelope.IsStale, AnalysisInput: analysisInput,
		})
	}
	if len(items) == 0 {
		items = append(items, personalDataEvidenceEvent{
			Source: envelope.Source, Dataset: envelope.Dataset, FetchedAt: envelope.FetchedAt,
			ExpiresAt: envelope.ExpiresAt, IsStale: envelope.IsStale,
		})
	}
	resultItems := make([]personalDataEvidenceEvent, 0, len(items))
	seen := make(map[string]struct{}, len(items))
	for _, item := range items {
		if !isPersonalDataSource(item.Source) {
			continue
		}
		// 证据事件仅用于来源提示，标题可能包含课程等业务字段，不能进入 SSE。
		key := item.Source + "|" + item.Dataset
		if item.FetchedAt != nil {
			key += "|" + item.FetchedAt.UTC().Format(time.RFC3339Nano)
		}
		if _, duplicate := seen[key]; duplicate {
			continue
		}
		seen[key] = struct{}{}
		item.Title = ""
		resultItems = append(resultItems, item)
		if len(resultItems) == 8 {
			break
		}
	}
	return resultItems
}

func sanitizeAcademicAnalysisInput(input map[string]interface{}) map[string]interface{} {
	if len(input) == 0 {
		return nil
	}
	result := make(map[string]interface{}, 5)
	for _, key := range []string{"earned_credits", "required_credits", "erke_earned", "erke_required"} {
		if value, ok := input[key].(float64); ok && value >= 0 && value <= 1000 {
			result[key] = value
		}
	}
	if rawCourses, ok := input["courses"].([]interface{}); ok {
		courses := make([]map[string]interface{}, 0, min(len(rawCourses), 500))
		for _, raw := range rawCourses {
			course, ok := raw.(map[string]interface{})
			if !ok {
				continue
			}
			name, _ := course["course_name"].(string)
			name = truncateHy3Text(strings.TrimSpace(name), 200)
			if name == "" {
				continue
			}
			item := map[string]interface{}{"course_name": name}
			if value, ok := course["grade"].(float64); ok && value >= 0 && value <= 100 {
				item["grade"] = value
			} else if value, ok := course["grade"].(string); ok && strings.TrimSpace(value) != "" {
				item["grade"] = truncateHy3Text(value, 100)
			}
			if value, ok := course["credits"].(float64); ok && value >= 0 && value <= 100 {
				item["credits"] = value
			}
			if value, ok := course["is_required"].(bool); ok {
				item["is_required"] = value
			}
			if value, ok := course["passed"].(bool); ok {
				item["passed"] = value
			}
			courses = append(courses, item)
			if len(courses) == 500 {
				break
			}
		}
		result["courses"] = courses
	}
	return result
}

func isPersonalDataSource(source string) bool {
	switch source {
	case "server_snapshot", "device_encrypted_cache", "remote_edu_fetch", "user_uploaded_snapshot", "hy3_mcp":
		return true
	default:
		return false
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
			finishReason := strings.ToLower(strings.TrimSpace(event.FinishReason))
			if finishReason != "tool_calls" || len(calls) == 0 {
				if code := providerFinishError(finishReason); code != "" {
					outcome.failureCode = code
					return "", nil, outcome
				}
			}
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

// fatalToolResultCode 阻止模型在个人数据工具明确失败时继续生成无依据的分析。
// 综合学业工具即使没有快照也会返回可解释的 missing/permission_required 结果，
// 这些状态应交给模型如实说明，而不是统一映射成服务不可用。
func fatalToolResultCode(toolName string, result json.RawMessage) string {
	if !json.Valid(result) {
		return ""
	}
	var envelope struct {
		Status    string `json:"status"`
		ErrorCode string `json:"error_code"`
	}
	if err := json.Unmarshal(result, &envelope); err != nil || envelope.Status == "" || envelope.Status == "ok" {
		return ""
	}
	if toolName == "academic_get_risk_analysis" {
		switch envelope.Status {
		case "available", "stale", "partial", "missing", "needs_refresh",
			"permission_required", "device_offline", "fetching":
			return ""
		default:
			return "personal_context_unavailable"
		}
	}
	if !strings.HasPrefix(toolName, "hy3_decision_") {
		return ""
	}
	if envelope.ErrorCode != "" {
		return envelope.ErrorCode
	}
	return "personal_context_unavailable"
}
