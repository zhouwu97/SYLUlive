package main

import (
	"context"
	"errors"
	"testing"
)

type examPaperStorageJobAttemptProcessorStub struct {
	jobID uint
	err   error
}

func (s *examPaperStorageJobAttemptProcessorStub) ProcessJob(_ context.Context, jobID uint) error {
	s.jobID = jobID
	return s.err
}

func TestNewExamPaperStorageJobAttemptCallsConfiguredProcessor(t *testing.T) {
	wantErr := errors.New("远端暂不可用")
	processor := &examPaperStorageJobAttemptProcessorStub{err: wantErr}
	attempt := newExamPaperStorageJobAttempt(processor)

	err := attempt(42)
	if !errors.Is(err, wantErr) {
		t.Fatalf("应返回处理器错误: %v", err)
	}
	if processor.jobID != 42 {
		t.Fatalf("应处理任务 42，实际为 %d", processor.jobID)
	}
}
