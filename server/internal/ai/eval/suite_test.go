package eval

import (
	"bytes"
	"context"
	"os"
	"testing"
)

func TestDefaultDeterministicRegressionSuite(t *testing.T) {
	cases := DefaultDeterministicCases()
	if len(cases) < 60 {
		t.Fatalf("deterministic case count = %d, want at least 60", len(cases))
	}
	summary, err := RunDeterministicSuite(context.Background(), cases)
	if err != nil {
		t.Fatal(err)
	}
	if len(summary.Failures) > 0 {
		for _, failure := range summary.Failures {
			t.Errorf("case %s failed: %s", failure.CaseID, failure.Result.FailureReason)
		}
	}
	if summary.Passed != summary.Cases {
		t.Fatalf("deterministic suite passed %d/%d", summary.Passed, summary.Cases)
	}
	baselineBytes, err := os.ReadFile("baseline.json")
	if err != nil {
		t.Fatal(err)
	}
	baseline, err := LoadBaseline(bytes.NewReader(baselineBytes))
	if err != nil {
		t.Fatal(err)
	}
	if violations := CompareBaseline(summary, baseline); len(violations) > 0 {
		for _, violation := range violations {
			t.Errorf("threshold violation %s: %.2f -> %.2f (%s)", violation.Metric, violation.Baseline, violation.Actual, violation.Reason)
		}
	}
	t.Log(FormatSummary(summary))
}

func TestModelBehaviorSuiteIsStatisticalAndSeparate(t *testing.T) {
	results, err := RunModelBehaviorSuite(context.Background(), []ModelBehaviorCase{{
		ID: "fixture.model.behavior", Repetitions: 5, MinSuccessRate: 0.8,
		Run: func(context.Context) AgentEvalResult { return AgentEvalResult{Success: true} },
	}})
	if err != nil {
		t.Fatal(err)
	}
	if len(results) != 1 || results[0].SuccessRate != 1 || !results[0].PassedGate {
		t.Fatalf("unexpected model behavior result: %+v", results)
	}
}

func TestCompareBaselineDetectsRegression(t *testing.T) {
	baseline := Baseline{
		Version: "test", Cases: 68, SuccessRate: 1, AverageToolCalls: 2,
		MaxP95ToolCalls: 3, MaxAverageToolGrowth: 0.2,
	}
	summary := SuiteSummary{
		Cases: 68, SuccessRate: 0.98, AverageToolCalls: 3, P95ToolCalls: 4,
		PermissionBypasses: 1,
	}
	violations := CompareBaseline(summary, baseline)
	if len(violations) < 3 {
		t.Fatalf("expected threshold violations, got %+v", violations)
	}
}
