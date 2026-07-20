package ai

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

type EvaluationCase struct {
	Name            string          `json:"name"`
	Kind            string          `json:"kind"`
	Answer          string          `json:"answer,omitempty"`
	AllowedChunkIDs []uint64        `json:"allowed_chunk_ids,omitempty"`
	Arguments       json.RawMessage `json:"arguments,omitempty"`
	ExpectedValid   bool            `json:"expected_valid"`
}

type EvaluationReport struct {
	Total    int      `json:"total"`
	Passed   int      `json:"passed"`
	Failed   int      `json:"failed"`
	Failures []string `json:"failures"`
}

// RunFixedEvaluation 执行不访问网络、结果可复现的安全与协议评测集。
func RunFixedEvaluation(directory string) (EvaluationReport, error) {
	paths, err := filepath.Glob(filepath.Join(directory, "*.jsonl"))
	if err != nil {
		return EvaluationReport{}, err
	}
	sort.Strings(paths)
	report := EvaluationReport{Failures: []string{}}
	for _, path := range paths {
		file, err := os.Open(path)
		if err != nil {
			return report, err
		}
		scanner := bufio.NewScanner(file)
		scanner.Buffer(make([]byte, 16<<10), 1<<20)
		line := 0
		for scanner.Scan() {
			line++
			if strings.TrimSpace(scanner.Text()) == "" {
				continue
			}
			var testCase EvaluationCase
			if err := json.Unmarshal(scanner.Bytes(), &testCase); err != nil {
				file.Close()
				return report, fmt.Errorf("%s:%d: %w", path, line, err)
			}
			report.Total++
			valid, err := evaluateFixedCase(testCase)
			if err != nil || valid != testCase.ExpectedValid {
				report.Failed++
				report.Failures = append(report.Failures, fmt.Sprintf("%s:%d:%s", filepath.Base(path), line, testCase.Name))
			} else {
				report.Passed++
			}
		}
		scanErr := scanner.Err()
		file.Close()
		if scanErr != nil {
			return report, scanErr
		}
	}
	if report.Total == 0 {
		return report, errorsNewNoEvaluationCases()
	}
	return report, nil
}

func evaluateFixedCase(testCase EvaluationCase) (bool, error) {
	switch testCase.Kind {
	case "citation":
		chunks := make([]RetrievedChunk, len(testCase.AllowedChunkIDs))
		for index, id := range testCase.AllowedChunkIDs {
			chunks[index] = RetrievedChunk{ChunkID: id, DocumentID: uint(index + 1), Title: "fixture"}
		}
		_, _, invalid := ValidateCitations(testCase.Answer, chunks)
		return !invalid, nil
	case "schedule_arguments":
		_, err := DecodeScheduleWindowsArguments(testCase.Arguments)
		return err == nil, nil
	default:
		return false, fmt.Errorf("unknown evaluation kind: %s", testCase.Kind)
	}
}

func errorsNewNoEvaluationCases() error { return fmt.Errorf("no evaluation cases") }
