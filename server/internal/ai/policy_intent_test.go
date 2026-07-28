package ai

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestPlanPolicyQueryUsesPythonPlannerContract(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		require.Equal(t, "/internal/rag/policy/plan", request.URL.Path)
		require.Equal(t, "internal-token", request.Header.Get("X-Internal-Service-Token"))
		var payload struct {
			Text string `json:"text"`
		}
		require.NoError(t, json.NewDecoder(request.Body).Decode(&payload))
		require.Equal(t, "补考成绩怎么算", payload.Text)
		response := PolicyQueryPlan{
			SchemaVersion: "1.0", PlannerName: "policy_query_planner", PlannerVersion: "policy-domain-rules-v1",
			Intent: "second_exam_grade", NormalizedQuery: payload.Text,
			ExactTerms: []string{"等级为D或F", "绩点为1或0"}, ExpandedTerms: []string{"二次考试", "重修"},
			PreferredDocTypes: []string{"school_undergraduate_retake_policy", "historical_school_second_exam_policy"},
			HistoryPolicy:     "include_when_required", VersionBoundary: "current_preferred_with_history", AllowHistorical: true,
		}
		require.NoError(t, json.NewEncoder(writer).Encode(response))
	}))
	defer server.Close()

	client, err := NewRAGClient(server.URL, "internal-token", server.Client())
	require.NoError(t, err)
	plan, err := client.PlanPolicyQuery(context.Background(), "补考成绩怎么算")
	require.NoError(t, err)
	require.Equal(t, "second_exam_grade", plan.Intent)
	require.Contains(t, plan.retrievalQuery(), "二次考试")
	require.True(t, plan.AllowHistorical)
}

func TestPlanPolicyQueryRejectsInconsistentHistoryBoundary(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		_ = json.NewEncoder(writer).Encode(PolicyQueryPlan{
			SchemaVersion: "1.0", PlannerName: "policy_query_planner", PlannerVersion: "v1",
			Intent: "general_policy", NormalizedQuery: "休学", HistoryPolicy: "exclude",
			VersionBoundary: "current_preferred_with_history", AllowHistorical: false,
		})
	}))
	defer server.Close()

	client, err := NewRAGClient(server.URL, "internal-token", server.Client())
	require.NoError(t, err)
	_, err = client.PlanPolicyQuery(context.Background(), "休学")
	require.Error(t, err)
}
