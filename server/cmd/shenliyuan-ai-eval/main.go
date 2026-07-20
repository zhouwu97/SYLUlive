package main

import (
	"encoding/json"
	"fmt"
	"os"

	"shenliyuan/internal/ai"
)

func main() {
	directory := "testdata/ai_eval"
	if len(os.Args) == 2 {
		directory = os.Args[1]
	}
	report, err := ai.RunFixedEvaluation(directory)
	encoded, _ := json.MarshalIndent(report, "", "  ")
	fmt.Println(string(encoded))
	if err != nil || report.Failed > 0 {
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
		}
		os.Exit(1)
	}
}
