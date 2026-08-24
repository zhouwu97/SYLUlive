package scenario

import (
	"context"
	"testing"
)

func TestDefaultScenarioSuite(t *testing.T) {
	cases := DefaultScenarios()
	if len(cases) < 20 {
		t.Fatalf("scenario count = %d, want at least 20", len(cases))
	}
	summary, err := RunSuite(context.Background(), cases)
	if err != nil {
		t.Fatal(err)
	}
	for _, failure := range summary.Failures {
		t.Errorf("scenario %s failed: %s", failure.CaseID, failure.Result.FailureReason)
	}
	if summary.Passed != summary.Cases {
		t.Fatalf("scenario suite passed %d/%d", summary.Passed, summary.Cases)
	}
	t.Log(FormatSummary(summary))
}

func TestScenarioThresholdDetectsMissingActionVerification(t *testing.T) {
	baseline := Baseline{
		Version: "test", Cases: 20, SuccessRate: 1, AverageToolCalls: 2,
		MaxAverageToolGrowth: 0.2, MaxP95ToolCalls: 5, MaxP95PlanningRounds: 5,
		MinActionCommits: 3, MinVerifiedCommits: 3,
	}
	violations := CompareBaseline(ScenarioSummary{Cases: 20, SuccessRate: .9, AverageToolCalls: 3, P95ToolCalls: 6, P95PlanningRounds: 6, ActionCommits: 2, VerifiedCommits: 1}, baseline)
	if len(violations) < 5 {
		t.Fatalf("expected threshold violations, got %+v", violations)
	}
}
