package ai

import (
	"encoding/json"
	"testing"
)

func TestExecutionProfileUsesTaskStructureBudgets(t *testing.T) {
	tests := []struct {
		name                    string
		goal                    GoalSpec
		mode                    ExecutionMode
		tools, rounds, external int
	}{
		{name: "fast", goal: GoalSpec{ActionIntent: "answer"}, mode: ExecutionFast, tools: 2, rounds: 1, external: 1},
		{name: "normal_personal", goal: GoalSpec{ActionIntent: "recommend", RequiresPersonalContext: true}, mode: ExecutionNormal, tools: 5, rounds: 3, external: 4},
		{name: "deep_plan", goal: GoalSpec{ActionIntent: "plan", RequiresPersonalContext: true}, mode: ExecutionDeep, tools: 12, rounds: 6, external: 8},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			profile := ExecutionProfileForGoal(test.goal)
			if profile.Mode != test.mode || profile.MaxToolCalls != test.tools || profile.MaxPlanningRounds != test.rounds || profile.MaxExternalCalls != test.external {
				t.Fatalf("profile=%+v", profile)
			}
			budget := BudgetForExecutionProfile(profile)
			if budget.MaxDuration <= 0 || budget.MaxToolCalls != test.tools {
				t.Fatalf("budget=%+v", budget)
			}
		})
	}
}

func TestExecutionProfileOnlyUpgrades(t *testing.T) {
	profile := DefaultExecutionProfile(ExecutionFast)
	if !UpgradeExecutionProfile(&profile, ExecutionNormal) || profile.Mode != ExecutionNormal {
		t.Fatalf("fast -> normal upgrade failed: %+v", profile)
	}
	if UpgradeExecutionProfile(&profile, ExecutionFast) || profile.Mode != ExecutionNormal {
		t.Fatalf("normal profile unexpectedly downgraded: %+v", profile)
	}
	if !UpgradeExecutionProfile(&profile, ExecutionDeep) || profile.Mode != ExecutionDeep {
		t.Fatalf("normal -> deep upgrade failed: %+v", profile)
	}
}

func TestExecutionComplexityReadsStructuredObservation(t *testing.T) {
	if got := ExecutionComplexityFromObservation(ToolResultEnvelope{Data: json.RawMessage(`{"items":[{"id":"a"},{"id":"b"}]}`)}); got != ExecutionNormal {
		t.Fatalf("candidate observation mode=%s", got)
	}
	if got := ExecutionComplexityFromObservation(ToolResultEnvelope{NextHints: []string{"compare", "validate"}}); got != ExecutionDeep {
		t.Fatalf("multi-hint observation mode=%s", got)
	}
}

func TestTraceMetricsRecordsModeUpgradeAndUnavailableUsage(t *testing.T) {
	var metrics AgentTraceMetrics
	metrics.Observe("run.started", []byte(`{"execution_mode":"fast"}`))
	metrics.Observe("execution_mode.upgraded", []byte(`{"from_mode":"fast","to_mode":"normal"}`))
	metrics.Observe("budget.exhausted", []byte(`{"budget_exhausted":true}`))
	if metrics.ExecutionMode != ExecutionFast || metrics.ModeUpgrades != 1 || metrics.FastEscalations != 1 || metrics.BudgetExhaustions != 1 {
		t.Fatalf("metrics=%+v", metrics)
	}
	if metrics.TokenUsageAvailable {
		t.Fatal("missing token usage must not be marked available")
	}
}
