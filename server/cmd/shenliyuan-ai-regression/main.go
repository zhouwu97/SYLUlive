package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"
	"time"

	"shenliyuan/internal/ai/eval"
)

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

func run(args []string, stdout, stderr io.Writer) int {
	flags := flag.NewFlagSet("shenliyuan-ai-regression", flag.ContinueOnError)
	flags.SetOutput(stderr)
	baselinePath := flags.String("baseline", "internal/ai/eval/baseline.json", "baseline.json 路径")
	timeout := flags.Duration("timeout", time.Minute, "Suite 超时")
	jsonOutput := flags.Bool("json", false, "输出机器可读 JSON")
	if err := flags.Parse(args); err != nil {
		return 2
	}
	if *timeout <= 0 {
		fmt.Fprintln(stderr, "--timeout 必须大于 0")
		return 2
	}
	baselineBytes, err := os.ReadFile(*baselinePath)
	if err != nil {
		fmt.Fprintf(stderr, "读取 baseline 失败：%v\n", err)
		return 1
	}
	baseline, err := eval.LoadBaseline(strings.NewReader(string(baselineBytes)))
	if err != nil {
		fmt.Fprintf(stderr, "解析 baseline 失败：%v\n", err)
		return 1
	}
	ctx, cancel := context.WithTimeout(context.Background(), *timeout)
	defer cancel()
	summary, err := eval.RunDeterministicSuite(ctx, eval.DefaultDeterministicCases())
	if err != nil {
		fmt.Fprintf(stderr, "Regression Suite 运行失败：%v\n", err)
		return 1
	}
	violations := eval.CompareBaseline(summary, baseline)
	if *jsonOutput {
		payload := struct {
			Summary    eval.SuiteSummary         `json:"summary"`
			Baseline   eval.Baseline             `json:"baseline"`
			Violations []eval.ThresholdViolation `json:"violations"`
		}{Summary: summary, Baseline: baseline, Violations: violations}
		encoder := json.NewEncoder(stdout)
		encoder.SetEscapeHTML(false)
		encoder.SetIndent("", "  ")
		if err := encoder.Encode(payload); err != nil {
			fmt.Fprintf(stderr, "输出 Regression Suite 报告失败：%v\n", err)
			return 1
		}
	} else {
		fmt.Fprintln(stdout, eval.FormatSummary(summary))
		if len(violations) > 0 {
			fmt.Fprintln(stdout, "")
			fmt.Fprintln(stdout, "Threshold Violations")
			for _, violation := range violations {
				fmt.Fprintf(stdout, "- %s: %.2f -> %.2f (%s)\n", violation.Metric, violation.Baseline, violation.Actual, violation.Reason)
			}
		}
	}
	if len(summary.Failures) > 0 || len(violations) > 0 {
		return 1
	}
	return 0
}
