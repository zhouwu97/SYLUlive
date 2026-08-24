package main

import (
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"
	"time"

	"shenliyuan/internal/ai/eval"
	"shenliyuan/internal/ai/eval/scenario"
)

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

func run(args []string, stdout, stderr io.Writer) int {
	flags := flag.NewFlagSet("shenliyuan-ai-regression", flag.ContinueOnError)
	flags.SetOutput(stderr)
	suite := flags.String("suite", "deterministic", "Suite 类型：deterministic、scenario 或 all")
	baselinePath := flags.String("baseline", "", "baseline.json 路径；all 模式分别使用两套默认 baseline")
	timeout := flags.Duration("timeout", time.Minute, "Suite 超时")
	jsonOutput := flags.Bool("json", false, "输出机器可读 JSON")
	if err := flags.Parse(args); err != nil {
		return 2
	}
	if *timeout <= 0 {
		fmt.Fprintln(stderr, "--timeout 必须大于 0")
		return 2
	}
	ctx, cancel := context.WithTimeout(context.Background(), *timeout)
	defer cancel()
	mode := strings.ToLower(strings.TrimSpace(*suite))
	switch mode {
	case "deterministic":
		baseline := *baselinePath
		if baseline == "" {
			baseline = "internal/ai/eval/baseline_deterministic.json"
		}
		summary, loaded, violations, err := runDeterministic(ctx, baseline)
		if err != nil {
			fmt.Fprintf(stderr, "%v\n", err)
			return 1
		}
		if err := writeDeterministic(stdout, summary, loaded, violations, *jsonOutput); err != nil {
			fmt.Fprintf(stderr, "%v\n", err)
			return 1
		}
		return boolExit(len(summary.Failures) == 0 && len(violations) == 0)
	case "scenario":
		baseline := *baselinePath
		if baseline == "" {
			baseline = "internal/ai/eval/scenario/baseline_scenario.json"
		}
		summary, loaded, violations, err := runScenario(ctx, baseline)
		if err != nil {
			fmt.Fprintf(stderr, "%v\n", err)
			return 1
		}
		if err := writeScenario(stdout, summary, loaded, violations, *jsonOutput); err != nil {
			fmt.Fprintf(stderr, "%v\n", err)
			return 1
		}
		return boolExit(len(summary.Failures) == 0 && len(violations) == 0)
	case "all":
		deterministicSummary, deterministicBaseline, deterministicViolations, err := runDeterministic(ctx, "internal/ai/eval/baseline_deterministic.json")
		if err != nil {
			fmt.Fprintf(stderr, "%v\n", err)
			return 1
		}
		scenarioSummary, scenarioBaseline, scenarioViolations, err := runScenario(ctx, "internal/ai/eval/scenario/baseline_scenario.json")
		if err != nil {
			fmt.Fprintf(stderr, "%v\n", err)
			return 1
		}
		if *jsonOutput {
			deterministicCases := deterministicSummary.Cases
			scenarioCases := scenarioSummary.Cases
			gate := map[string]int{
				"deterministic_cases":  deterministicCases,
				"deterministic_passed": deterministicSummary.Passed,
				"scenario_cases":       scenarioCases,
				"scenario_passed":      scenarioSummary.Passed,
				"total_cases":          deterministicCases + scenarioCases,
				"total_passed":         deterministicSummary.Passed + scenarioSummary.Passed,
			}
			payload := struct {
				Deterministic interface{}    `json:"deterministic"`
				Scenario      interface{}    `json:"scenario"`
				Gate          map[string]int `json:"gate"`
			}{
				Deterministic: map[string]interface{}{"summary": deterministicSummary, "baseline": deterministicBaseline, "violations": deterministicViolations},
				Scenario:      map[string]interface{}{"summary": scenarioSummary, "baseline": scenarioBaseline, "violations": scenarioViolations},
				Gate:          gate,
			}
			encoder := json.NewEncoder(stdout)
			encoder.SetEscapeHTML(false)
			encoder.SetIndent("", "  ")
			if err := encoder.Encode(payload); err != nil {
				fmt.Fprintf(stderr, "输出 Regression Suite 报告失败：%v\n", err)
				return 1
			}
		} else {
			fmt.Fprintln(stdout, eval.FormatSummary(deterministicSummary))
			fmt.Fprint(stdout, "\n--- Scenario ---\n\n")
			fmt.Fprintln(stdout, scenario.FormatSummary(scenarioSummary))
			fmt.Fprintf(stdout, "\nRegression Gate: deterministic=%d/%d scenario=%d/%d total=%d/%d\n",
				deterministicSummary.Passed, deterministicSummary.Cases,
				scenarioSummary.Passed, scenarioSummary.Cases,
				deterministicSummary.Passed+scenarioSummary.Passed,
				deterministicSummary.Cases+scenarioSummary.Cases)
		}
		return boolExit(len(deterministicSummary.Failures) == 0 && len(deterministicViolations) == 0 && len(scenarioSummary.Failures) == 0 && len(scenarioViolations) == 0)
	default:
		fmt.Fprintln(stderr, "--suite 只支持 deterministic、scenario 或 all")
		return 2
	}
}

func runDeterministic(ctx context.Context, path string) (eval.SuiteSummary, eval.Baseline, []eval.ThresholdViolation, error) {
	baseline, err := loadDeterministicBaseline(path)
	if err != nil {
		return eval.SuiteSummary{}, baseline, nil, err
	}
	summary, err := eval.RunDeterministicSuite(ctx, eval.DefaultDeterministicCases())
	if err != nil {
		return summary, baseline, nil, fmt.Errorf("Regression Suite 运行失败：%w", err)
	}
	return summary, baseline, eval.CompareBaseline(summary, baseline), nil
}

func runScenario(ctx context.Context, path string) (scenario.ScenarioSummary, scenario.Baseline, []scenario.ThresholdViolation, error) {
	baseline, err := loadScenarioBaseline(path)
	if err != nil {
		return scenario.ScenarioSummary{}, baseline, nil, err
	}
	summary, err := scenario.RunSuite(ctx, scenario.DefaultScenarios())
	if err != nil {
		return summary, baseline, nil, fmt.Errorf("Scenario Suite 运行失败：%w", err)
	}
	return summary, baseline, scenario.CompareBaseline(summary, baseline), nil
}

func loadDeterministicBaseline(path string) (eval.Baseline, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return eval.Baseline{}, fmt.Errorf("读取 deterministic baseline 失败：%w", err)
	}
	baseline, err := eval.LoadBaseline(bytes.NewReader(data))
	if err != nil {
		return baseline, fmt.Errorf("解析 deterministic baseline 失败：%w", err)
	}
	return baseline, nil
}

func loadScenarioBaseline(path string) (scenario.Baseline, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return scenario.Baseline{}, fmt.Errorf("读取 scenario baseline 失败：%w", err)
	}
	baseline, err := scenario.LoadBaseline(bytes.NewReader(data))
	if err != nil {
		return baseline, fmt.Errorf("解析 scenario baseline 失败：%w", err)
	}
	return baseline, nil
}

func writeDeterministic(stdout io.Writer, summary eval.SuiteSummary, baseline eval.Baseline, violations []eval.ThresholdViolation, jsonOutput bool) error {
	if jsonOutput {
		return encodeJSON(stdout, struct {
			Summary    eval.SuiteSummary         `json:"summary"`
			Baseline   eval.Baseline             `json:"baseline"`
			Violations []eval.ThresholdViolation `json:"violations"`
		}{summary, baseline, violations})
	}
	fmt.Fprintln(stdout, eval.FormatSummary(summary))
	writeViolations(stdout, violations)
	return nil
}

func writeScenario(stdout io.Writer, summary scenario.ScenarioSummary, baseline scenario.Baseline, violations []scenario.ThresholdViolation, jsonOutput bool) error {
	if jsonOutput {
		return encodeJSON(stdout, struct {
			Summary    scenario.ScenarioSummary      `json:"summary"`
			Baseline   scenario.Baseline             `json:"baseline"`
			Violations []scenario.ThresholdViolation `json:"violations"`
		}{summary, baseline, violations})
	}
	fmt.Fprintln(stdout, scenario.FormatSummary(summary))
	writeViolations(stdout, violations)
	return nil
}

func encodeJSON(stdout io.Writer, value interface{}) error {
	encoder := json.NewEncoder(stdout)
	encoder.SetEscapeHTML(false)
	encoder.SetIndent("", "  ")
	return encoder.Encode(value)
}

func writeViolations(stdout io.Writer, violations interface{}) {
	// 文本报告由各 Suite 自己输出摘要；threshold 细节保留在 JSON，避免重复定义泛型格式。
	_ = violations
}

func boolExit(ok bool) int {
	if ok {
		return 0
	}
	return 1
}
