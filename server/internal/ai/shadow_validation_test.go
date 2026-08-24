package ai

import "testing"

func TestAgentFeatureFlagsStableRolloutAndFilters(t *testing.T) {
	flags := AgentFeatureFlags{
		Enabled:             true,
		RolloutPercent:      100,
		AppVersionAllowlist: []string{"2.6.0"},
		ModeAllowlist:       []string{"normal"},
	}
	input := FeatureFlagInput{UserID: 27, AppVersion: "2.6.0", Mode: ExecutionNormal}
	if !flags.AgentAllowed(input) {
		t.Fatal("expected matching user/version/mode to enter rollout")
	}
	if flags.AgentAllowed(FeatureFlagInput{UserID: 27, AppVersion: "2.5.0", Mode: ExecutionNormal}) {
		t.Fatal("unexpected rollout for an app version outside allowlist")
	}
	if flags.AgentAllowed(FeatureFlagInput{UserID: 27, AppVersion: "2.6.0", Mode: ExecutionDeep}) {
		t.Fatal("unexpected rollout for a mode outside allowlist")
	}
	first, second := flags.AgentAllowed(input), flags.AgentAllowed(input)
	if first != second {
		t.Fatal("rollout decision is not deterministic")
	}
}

func TestAgentFeatureFlagsExplicitUserAndShadowSafety(t *testing.T) {
	flags := AgentFeatureFlags{
		Enabled:        true,
		RolloutPercent: 0,
		RolloutUserIDs: []uint{7},
		ShadowEnabled:  true,
		ShadowPercent:  0,
		ActionsEnabled: true,
	}
	input := FeatureFlagInput{UserID: 7, RunID: "run-1", Mode: ExecutionFast}
	snapshot := flags.Snapshot(input)
	if !snapshot.AgentEnabled || !snapshot.ActionsEnabled {
		t.Fatalf("explicit user was not allowed: %+v", snapshot)
	}
	if !snapshot.ShadowEnabled {
		t.Fatal("explicit user should enter shadow even at 0 percent")
	}
	shadow := NewShadowExecution("trace-1", ExecutionNormal)
	shadow.ObserveActionProposal()
	payload := shadow.Payload()
	if payload["shadow_only"] != true || payload["action_commits"] != 0 || payload["blocked_actions"] != 1 {
		t.Fatalf("shadow safety contract violated: %+v", payload)
	}
}

func TestFailureReasonAndRegressionCandidateContract(t *testing.T) {
	if got := FailureReasonForCode("mcp_v5_unavailable"); got != FailureCapabilityWrong {
		t.Fatalf("failure mapping=%s", got)
	}
	candidate := RegressionScenarioCandidate{
		CaseID: "real_trace.run-1.answer_wrong", SourceTraceID: "run-1",
		FailureReason: FailureAnswerWrong, Candidate: true,
	}
	payload := candidate.Payload()
	if payload["case_id"] != candidate.CaseID || payload["source_trace_id"] != candidate.SourceTraceID {
		t.Fatalf("candidate contract lost trace identity: %+v", payload)
	}
	var metrics AgentTraceMetrics
	metrics.Observe(string(UserSignalCorrection), nil)
	metrics.Observe(string(UserSignalUsefulAnswer), []byte(`{"time_to_useful_answer_ms":42}`))
	metrics.Observe("run.failed", []byte(`{"failure_reason":"answer_wrong"}`))
	if metrics.UserCorrections != 1 || metrics.UsefulAnswers != 1 || metrics.TimeToUsefulAnswerMs != 42 || metrics.FailureTaxonomy[string(FailureAnswerWrong)] != 1 {
		t.Fatalf("real-user metrics contract violated: %+v", metrics)
	}
}
