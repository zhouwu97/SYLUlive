package ai

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

func policyInt(value int) *int    { return &value }
func policyBool(value bool) *bool { return &value }

func validPolicyRAGResult(requestID string) PolicyRAGResult {
	return PolicyRAGResult{
		RequestID: requestID, SchemaVersion: PolicyRAGSchemaVersion,
		ChainName: "shenliyuan_policy_rag", ChainVersion: "answer-citations-v3",
		Status: "completed", AnswerMode: "verified_campus", Answer: "请履行审批手续。[1]",
		Sources: []PolicyRAGSource{{
			SourceID: "R1", DocumentID: 9, ChunkID: 18, CitationNumber: 1, Title: "学生手册",
			Content: "学生请假应履行审批手续。",
		}},
		Usage: &PolicyRAGUsage{
			Provider: "fake", Model: "fake-v1", InputTokens: policyInt(20),
			OutputTokens: policyInt(8), CacheHitTokens: policyInt(0), Metered: policyBool(true),
		},
	}
}

func validGeneralRAGResult(requestID string) PolicyRAGResult {
	return PolicyRAGResult{
		RequestID: requestID, SchemaVersion: PolicyRAGSchemaVersion,
		ChainName: "shenliyuan_policy_rag", ChainVersion: "campus-assistant-release-v6",
		Status: "general_completed", AnswerMode: "general_answer",
		Answer: "你好，我是沈理校园 AI。",
		Usage: &PolicyRAGUsage{
			Provider: "fake", Model: "fake-v1", InputTokens: policyInt(12),
			OutputTokens: policyInt(6), CacheHitTokens: policyInt(0), Metered: policyBool(true),
		},
	}
}

func TestRAGClientQueryPolicyUsesInternalTokenAndValidatesUsage(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		require.Equal(t, "/internal/rag/policy/query", request.URL.Path)
		require.Equal(t, "internal-token", request.Header.Get("X-Internal-Service-Token"))
		var input PolicyRAGInput
		require.NoError(t, json.NewDecoder(request.Body).Decode(&input))
		require.Equal(t, "query-1", input.RequestID)
		require.Equal(t, defaultPolicyMaxSources, input.MaxSources)
		writer.Header().Set("Content-Type", "application/json")
		require.NoError(t, json.NewEncoder(writer).Encode(validPolicyRAGResult(input.RequestID)))
	}))
	defer server.Close()

	client, err := NewRAGClient(server.URL, "internal-token", server.Client())
	require.NoError(t, err)
	result, err := client.QueryPolicy(context.Background(), PolicyRAGInput{
		RequestID: "query-1", Question: "怎么请假",
	})
	require.NoError(t, err)
	require.Equal(t, "answer-citations-v3", result.ChainVersion)
	require.Equal(t, 20, *result.Usage.InputTokens)
}

func TestRAGClientQueryPolicyRejectsMissingOrZeroUsage(t *testing.T) {
	tests := []struct {
		name   string
		mutate func(*PolicyRAGResult)
	}{
		{name: "missing", mutate: func(result *PolicyRAGResult) { result.Usage.OutputTokens = nil }},
		{name: "zero", mutate: func(result *PolicyRAGResult) {
			result.Usage.InputTokens = policyInt(0)
			result.Usage.OutputTokens = policyInt(0)
		}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
				result := validPolicyRAGResult("query-1")
				test.mutate(&result)
				_ = json.NewEncoder(writer).Encode(result)
			}))
			defer server.Close()
			client, err := NewRAGClient(server.URL, "internal-token", server.Client())
			require.NoError(t, err)
			_, err = client.QueryPolicy(context.Background(), PolicyRAGInput{RequestID: "query-1", Question: "请假"})
			require.Error(t, err)
		})
	}
}

func TestPolicyRAGResultRejectsForgedNumberedCitation(t *testing.T) {
	result := validPolicyRAGResult("forged")
	result.Answer = "伪造结论[9]"
	require.Error(t, result.validate("forged"))

	result = validPolicyRAGResult("source-mismatch")
	result.Sources[0].SourceID = "R9"
	require.Error(t, result.validate("source-mismatch"))
}

func TestPolicyRAGResultAcceptsGeneralAnswerWithoutSources(t *testing.T) {
	result := validGeneralRAGResult("general")
	require.NoError(t, result.validate("general"))

	result.AnswerMode = "verified_campus"
	require.Error(t, result.validate("general"))
}

func TestRAGClientStreamPolicyConsumesVersionedEvents(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		writer.Header().Set("Content-Type", "text/event-stream")
		result := validPolicyRAGResult("stream-1")
		events := []PolicyRAGEvent{
			{RequestID: "stream-1", SchemaVersion: PolicyRAGSchemaVersion, ChainName: result.ChainName, ChainVersion: result.ChainVersion, Sequence: 1, Type: "planning", Timestamp: time.Now().Format(time.RFC3339Nano)},
			{RequestID: "stream-1", SchemaVersion: PolicyRAGSchemaVersion, ChainName: result.ChainName, ChainVersion: result.ChainVersion, Sequence: 2, Type: "reranking", Timestamp: time.Now().Format(time.RFC3339Nano)},
			{RequestID: "stream-1", SchemaVersion: PolicyRAGSchemaVersion, ChainName: result.ChainName, ChainVersion: result.ChainVersion, Sequence: 3, Type: "token", Timestamp: time.Now().Format(time.RFC3339Nano), Delta: result.Answer},
			{RequestID: "stream-1", SchemaVersion: PolicyRAGSchemaVersion, ChainName: result.ChainName, ChainVersion: result.ChainVersion, Sequence: 4, Type: "completed", Timestamp: time.Now().Format(time.RFC3339Nano), Result: &result},
		}
		for _, event := range events {
			data, _ := json.Marshal(event)
			_, _ = fmt.Fprintf(writer, "event: policy_rag\ndata: %s\n\n", data)
		}
	}))
	defer server.Close()

	client, err := NewRAGClient(server.URL, "internal-token", server.Client())
	require.NoError(t, err)
	stream, err := client.StreamPolicy(context.Background(), PolicyRAGInput{RequestID: "stream-1", Question: "请假"})
	require.NoError(t, err)
	defer stream.Close()
	for _, eventType := range []string{"planning", "reranking", "token", "completed"} {
		event, nextErr := stream.Next(context.Background())
		require.NoError(t, nextErr)
		require.Equal(t, eventType, event.Type)
	}
}

func TestRAGClientStreamPolicyCancellationReachesRemoteRequest(t *testing.T) {
	remoteCancelled := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		writer.Header().Set("Content-Type", "text/event-stream")
		writer.WriteHeader(http.StatusOK)
		writer.(http.Flusher).Flush()
		<-request.Context().Done()
		close(remoteCancelled)
	}))
	defer server.Close()

	client, err := NewRAGClient(server.URL, "internal-token", server.Client())
	require.NoError(t, err)
	ctx, cancel := context.WithCancel(context.Background())
	stream, err := client.StreamPolicy(ctx, PolicyRAGInput{RequestID: "cancel-1", Question: "请假"})
	require.NoError(t, err)
	cancel()
	_, err = stream.Next(ctx)
	require.ErrorIs(t, err, context.Canceled)
	require.Eventually(t, func() bool {
		select {
		case <-remoteCancelled:
			return true
		default:
			return false
		}
	}, time.Second, 10*time.Millisecond)
	require.NoError(t, stream.Close())
}
