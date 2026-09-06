package ai

import (
	"testing"

	"github.com/stretchr/testify/require"
)

func TestAgentFailureClassForCodeCoversA4Taxonomy(t *testing.T) {
	cases := map[string]AgentFailureClass{
		"provider_timeout":              FailureProviderTimeout,
		"provider_stream_closed":        FailureProviderStreamReset,
		"rag_timeout":                   FailureRetrievalTimeout,
		"tool_timeout":                  FailureToolTimeout,
		"tool_execution_failed":         FailureToolError,
		"permission_denied":             FailureAuthorizationDenied,
		"knowledge_stale":               FailureKnowledgeStale,
		"network_disconnected":          FailureNetworkDisconnected,
		"context_limit_exceeded":        FailureContextLimit,
		"output_limit_reached":          FailureContextLimit,
		"context_cancelled":             FailureCancelled,
		"checkpoint_reconnect_required": FailureReconnect,
	}
	for code, expected := range cases {
		require.Equal(t, expected, AgentFailureClassForCode(code), code)
		require.NotEmpty(t, AgentRecoveryPathForFailure(expected), code)
	}
}

func TestAgentFailureClassDoesNotExposeOriginalCodeInRecoveryPath(t *testing.T) {
	path := AgentRecoveryPathForFailure(AgentFailureClassForCode("internal-db-password-error"))
	require.Equal(t, "explain_failure", path)
	require.NotContains(t, path, "password")
}

func TestAgentFailureEventPayloadIncludesStableRecoveryFields(t *testing.T) {
	payload := agentFailureEventPayload("tool_timeout", true)
	require.Equal(t, FailureToolTimeout, payload["failure_class"])
	require.Equal(t, "retry_tool_or_explain", payload["recovery_path"])
	require.Equal(t, true, payload["retryable"])
	require.Equal(t, FailureCapabilityWrong, payload["failure_reason"])
}

func TestAgentFailureClassForCodeDistinguishesStreamAndNetworkReset(t *testing.T) {
	require.Equal(t, FailureProviderStreamReset, AgentFailureClassForCode("provider_stream_disconnected"))
	require.Equal(t, FailureNetworkDisconnected, AgentFailureClassForCode("network_disconnected"))
	require.Equal(t, FailureReconnect, AgentFailureClassForCode("server_restarted"))
}

func TestAgentTraceMetricsCountsCancelledAndLegacyFailureEvents(t *testing.T) {
	var metrics AgentTraceMetrics
	metrics.Observe("run.cancelled", []byte(`{"failure_class":"cancelled"}`))
	metrics.Observe("run.failed", []byte(`{"code":"provider_timeout"}`))
	require.True(t, metrics.RunFailed)
	require.Equal(t, 1, metrics.FailureClasses[string(FailureCancelled)])
	require.Equal(t, 1, metrics.FailureClasses[string(FailureProviderTimeout)])
}
