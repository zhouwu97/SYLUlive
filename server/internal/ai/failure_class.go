package ai

import "strings"

// AgentFailureClass 是 A4 观测和恢复路径共用的稳定故障分类。
type AgentFailureClass string

const (
	FailureProviderTimeout     AgentFailureClass = "provider_timeout"
	FailureProviderStreamReset AgentFailureClass = "provider_stream_reset"
	FailureRetrievalTimeout    AgentFailureClass = "retrieval_timeout"
	FailureToolTimeout         AgentFailureClass = "tool_timeout"
	FailureToolError           AgentFailureClass = "tool_error"
	FailureAuthorizationDenied AgentFailureClass = "authorization_denied"
	FailureKnowledgeStale      AgentFailureClass = "knowledge_stale"
	FailureNetworkDisconnected AgentFailureClass = "network_disconnected"
	FailureContextLimit        AgentFailureClass = "context_limit"
	FailureCancelled           AgentFailureClass = "cancelled"
	FailureReconnect           AgentFailureClass = "reconnect"
	FailureUnknown             AgentFailureClass = "unknown"
)

// Valid 判断故障分类是否属于对外稳定契约。
func (class AgentFailureClass) Valid() bool {
	switch class {
	case FailureProviderTimeout, FailureProviderStreamReset, FailureRetrievalTimeout,
		FailureToolTimeout, FailureToolError, FailureAuthorizationDenied,
		FailureKnowledgeStale, FailureNetworkDisconnected, FailureContextLimit,
		FailureCancelled, FailureReconnect, FailureUnknown:
		return true
	default:
		return false
	}
}

// AgentFailureClassForCode 将内部错误码收敛成不含实现细节的观测分类。
func AgentFailureClassForCode(code string) AgentFailureClass {
	normalized := strings.ToLower(strings.TrimSpace(code))
	switch {
	case normalized == "" || normalized == "unknown_provider_error":
		return FailureUnknown
	case strings.Contains(normalized, "cancel") || normalized == "context_cancelled":
		return FailureCancelled
	case strings.Contains(normalized, "reconnect") || strings.Contains(normalized, "resume") || strings.Contains(normalized, "server_restart"):
		return FailureReconnect
	case strings.Contains(normalized, "context") && (strings.Contains(normalized, "limit") || strings.Contains(normalized, "exceed") || strings.Contains(normalized, "length")):
		return FailureContextLimit
	case strings.Contains(normalized, "output_limit") || normalized == "max_tokens_exceeded":
		return FailureContextLimit
	case strings.Contains(normalized, "permission") || strings.Contains(normalized, "authoriz") || strings.Contains(normalized, "grant") || strings.Contains(normalized, "consent"):
		return FailureAuthorizationDenied
	case strings.Contains(normalized, "stale") || strings.Contains(normalized, "expired") || strings.Contains(normalized, "knowledge"):
		return FailureKnowledgeStale
	case strings.Contains(normalized, "stream") && (strings.Contains(normalized, "closed") || strings.Contains(normalized, "reset") || strings.Contains(normalized, "disconnect")):
		return FailureProviderStreamReset
	case strings.Contains(normalized, "network") || strings.Contains(normalized, "disconnect") || strings.Contains(normalized, "connection_reset"):
		return FailureNetworkDisconnected
	case strings.HasPrefix(normalized, "provider_") && strings.Contains(normalized, "timeout"):
		return FailureProviderTimeout
	case normalized == "provider_timeout" || strings.Contains(normalized, "provider") && strings.Contains(normalized, "deadline"):
		return FailureProviderTimeout
	case strings.Contains(normalized, "retriev") || strings.HasPrefix(normalized, "rag_"):
		if strings.Contains(normalized, "timeout") || strings.Contains(normalized, "unavailable") || strings.Contains(normalized, "failed") {
			return FailureRetrievalTimeout
		}
	case strings.Contains(normalized, "tool") || strings.Contains(normalized, "mcp_"):
		if strings.Contains(normalized, "timeout") || strings.Contains(normalized, "deadline") {
			return FailureToolTimeout
		}
		return FailureToolError
	case strings.Contains(normalized, "timeout") || strings.Contains(normalized, "deadline"):
		return FailureProviderTimeout
	}
	return FailureUnknown
}

// AgentRecoveryPathForFailure 返回客户端可展示的稳定恢复动作标签。
func AgentRecoveryPathForFailure(class AgentFailureClass) string {
	switch class {
	case FailureProviderTimeout, FailureProviderStreamReset, FailureNetworkDisconnected, FailureReconnect:
		return "retry_or_reconnect"
	case FailureRetrievalTimeout, FailureKnowledgeStale:
		return "safe_degrade_or_refuse"
	case FailureToolTimeout, FailureToolError:
		return "retry_tool_or_explain"
	case FailureAuthorizationDenied:
		return "request_authorization"
	case FailureContextLimit:
		return "bound_context"
	case FailureCancelled:
		return "acknowledge_cancel"
	default:
		return "explain_failure"
	}
}

// agentFailureEventPayload 生成 run.failed 的稳定脱敏字段。
// failure_reason 保留旧的反馈分类，failure_class 供 A4 故障观测使用。
func agentFailureEventPayload(code string, retryable bool) map[string]interface{} {
	class := AgentFailureClassForCode(code)
	return map[string]interface{}{
		"code":           code,
		"retryable":      retryable,
		"failure_reason": FailureReasonForCode(code),
		"failure_class":  class,
		"recovery_path":  AgentRecoveryPathForFailure(class),
	}
}
