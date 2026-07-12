package main

import (
	"errors"
	"testing"
)

func TestPendingExamPaperStorageJobAttemptIsNonNilAndReturnsDedicatedError(t *testing.T) {
	attempt := pendingExamPaperStorageJobAttempt
	if attempt == nil {
		t.Fatal("主进程必须为远端上传配置明确的存储任务尝试回调")
	}
	if err := attempt(42); !errors.Is(err, errExamPaperStorageJobProcessorPending) {
		t.Fatalf("未配置任务处理器时应返回专用错误: %v", err)
	}
}
