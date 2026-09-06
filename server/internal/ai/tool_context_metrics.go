package ai

import (
	"encoding/json"
	"unicode/utf8"
)

const (
	toolContextRoutingUnifiedShortlist    = "unified_shortlist"
	toolContextRoutingLegacyDeterministic = "legacy_deterministic"
	toolContextRoutingNoToolsForPolicyRAG = "verified_policy_no_tools"
	toolContextRoutingResumeDeterministic = "resume_deterministic"
)

// ToolContextMetrics 是发送给模型前工具定义上下文的脱敏度量。
// 它只保存数量、序列化规模和固定路由类型，不能包含问题、工具参数或 Schema 原文。
type ToolContextMetrics struct {
	RegisteredToolCount           int    `json:"registered_tool_count"`
	ModelVisibleToolCount         int    `json:"model_visible_tool_count"`
	SchemaBytes                   int    `json:"tool_schema_bytes"`
	SchemaTokenEstimate           int    `json:"tool_schema_token_estimate"`
	RoutingMode                   string `json:"tool_routing_mode"`
	SuppressedByVerifiedPolicyRAG bool   `json:"tools_suppressed_by_verified_policy_rag"`
	SchemaMeasurementAvailable    bool   `json:"tool_schema_measurement_available"`
}

// MeasureToolContext 计算单轮模型可见工具集合的固定口径。
// Token 估算只用于不同提交间的趋势比较，不能替代 Provider 回传的实际 usage 或费用结算。
func MeasureToolContext(
	registered []ToolDefinition,
	visible []ToolDefinition,
	routingMode string,
	suppressedByVerifiedPolicyRAG bool,
) ToolContextMetrics {
	metrics := ToolContextMetrics{
		RegisteredToolCount:           len(registered),
		ModelVisibleToolCount:         len(visible),
		RoutingMode:                   routingMode,
		SuppressedByVerifiedPolicyRAG: suppressedByVerifiedPolicyRAG,
	}
	if len(visible) == 0 {
		// 没有向模型发送工具定义时，真实 Schema 大小为零；不要把 nil
		// 切片的 JSON 表示 null 计入输入上下文。
		metrics.SchemaMeasurementAvailable = true
		return metrics
	}
	encoded, err := json.Marshal(visible)
	if err != nil {
		return metrics
	}
	metrics.SchemaMeasurementAvailable = true
	metrics.SchemaBytes = len(encoded)
	metrics.SchemaTokenEstimate = estimateSerializedToolSchemaTokens(encoded)
	return metrics
}

// estimateSerializedToolSchemaTokens 对 ASCII 按四字符约一 token、非 ASCII 按一 rune
// 约一 token 的保守近似，用于避免中文 Schema 被单纯字节数系统性低估。
func estimateSerializedToolSchemaTokens(encoded []byte) int {
	if len(encoded) == 0 {
		return 0
	}
	units := 0
	for len(encoded) > 0 {
		runeValue, size := utf8.DecodeRune(encoded)
		if runeValue == utf8.RuneError && size == 1 {
			units += 4
			encoded = encoded[1:]
			continue
		}
		if runeValue <= 0x7f {
			units++
		} else {
			units += 4
		}
		encoded = encoded[size:]
	}
	return (units + 3) / 4
}
