package main

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"testing"
	"time"

	"shenliyuan/internal/ai"
	"shenliyuan/internal/ai/mcpclient"
)

type healthTool struct{ name string }

func (tool healthTool) Name() string    { return tool.name }
func (tool healthTool) Version() string { return "test" }
func (tool healthTool) Definition() ai.ToolDefinition {
	return ai.ToolDefinition{Name: tool.name, Parameters: map[string]interface{}{"type": "object"}}
}
func (tool healthTool) Execute(context.Context, uint, json.RawMessage) (interface{}, error) {
	return map[string]interface{}{}, nil
}

type externalMCPHealthStub struct {
	status mcpclient.ExternalMCPHealthStatus
}

func (stub externalMCPHealthStub) Healthy() bool { return stub.status.Healthy }
func (stub externalMCPHealthStub) HealthStatus() mcpclient.ExternalMCPHealthStatus {
	return stub.status
}

func TestExternalMCPHealthPayloadUsesVerifiedSessionAndRegisteredTools(t *testing.T) {
	registry, err := ai.NewToolRegistry(nil,
		healthTool{name: "hy3_decision.compare_competitions"},
		healthTool{name: "hy3_decision.analyze_academic"},
		healthTool{name: "hy3_decision.plan_student_week"},
	)
	if err != nil {
		t.Fatalf("create registry: %v", err)
	}
	client := externalMCPHealthStub{status: mcpclient.ExternalMCPHealthStatus{
		Healthy: true, Mode: "live", ContractVersion: "sylulive-hy3/1", AvailableTools: 3,
	}}

	payload := externalMCPHealthPayload(true, client, registry)
	if !payload.Configured || !payload.Healthy || payload.Mode != "live" ||
		payload.ContractVersion != "sylulive-hy3/1" || payload.AvailableTools != 3 {
		t.Fatalf("unexpected external MCP health payload: %#v", payload)
	}
}

func TestNewAIRuntimeRegistriesAppliesSchoolCapabilityCutAtStartup(t *testing.T) {
	tools := []ai.PureReadTool{
		healthTool{name: "academic.get_risk_analysis"},
		healthTool{name: "academic.summary"},
		healthTool{name: "device.academic.ensure_fresh_bundle"},
		healthTool{name: "hy3_decision.plan_student_week"},
		healthTool{name: "campus.search_policy"},
	}

	toolRegistry, capabilityRegistry, err := newAIRuntimeRegistries(nil, true, tools...)
	if err != nil {
		t.Fatalf("装配 C3 AI Runtime 失败: %v", err)
	}
	for _, name := range []string{
		"academic.get_risk_analysis",
		"academic.summary",
		"device.academic.ensure_fresh_bundle",
		"hy3_decision.plan_student_week",
	} {
		if toolRegistry.HasTool(name) {
			t.Fatalf("C3 后学校个人工具仍进入运行时注册表: %s", name)
		}
	}
	if !toolRegistry.HasTool("campus.search_policy") {
		t.Fatal("C3 不应移除公开校园资讯工具")
	}

	capabilities := make(map[string]ai.AgentCapability)
	for _, capability := range capabilityRegistry.Public() {
		capabilities[capability.ID] = capability
	}
	for _, id := range []string{
		"academic.summary",
		"academic.personal_read",
		"academic.personal_refresh",
		"schedule.free_windows",
		"schedule.validate_plan",
	} {
		if _, exists := capabilities[id]; exists {
			t.Fatalf("C3 后能力目录仍声明学校个人能力: %s", id)
		}
	}
	publicCapability, exists := capabilities["campus.policy_search"]
	if !exists || !publicCapability.Available {
		t.Fatalf("公开校园资讯能力应继续可用: %#v", publicCapability)
	}
}

func TestNewAIRuntimeRegistriesKeepsSchoolCapabilitiesBeforeCut(t *testing.T) {
	toolRegistry, capabilityRegistry, err := newAIRuntimeRegistries(
		nil,
		false,
		healthTool{name: "academic.summary"},
	)
	if err != nil {
		t.Fatalf("装配迁移期 AI Runtime 失败: %v", err)
	}
	if !toolRegistry.HasTool("academic.summary") {
		t.Fatal("C3 前不应提前移除学校个人工具")
	}
	for _, capability := range capabilityRegistry.Public() {
		if capability.ID == "academic.summary" {
			return
		}
	}
	t.Fatal("C3 前能力目录应保留迁移期学业能力")
}

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

type gracefulHTTPServerStub struct {
	started     chan struct{}
	stop        chan struct{}
	shutdownCtx context.Context
}

func (s *gracefulHTTPServerStub) ListenAndServe() error {
	close(s.started)
	<-s.stop
	return http.ErrServerClosed
}

func (s *gracefulHTTPServerStub) Shutdown(ctx context.Context) error {
	s.shutdownCtx = ctx
	close(s.stop)
	return nil
}

func TestServeUntilShutdownUsesDeadlineAndWaitsForServer(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	server := &gracefulHTTPServerStub{started: make(chan struct{}), stop: make(chan struct{})}
	done := make(chan error, 1)
	go func() { done <- serveUntilShutdown(ctx, server, 2*time.Second) }()
	<-server.started
	cancel()

	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("优雅关闭失败: %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("HTTP 服务未在取消后退出")
	}
	if server.shutdownCtx == nil {
		t.Fatal("未调用 HTTP Shutdown")
	}
	deadline, ok := server.shutdownCtx.Deadline()
	if !ok || time.Until(deadline) <= 0 || time.Until(deadline) > 2*time.Second {
		t.Fatalf("Shutdown 应使用两秒内的期限: %v", deadline)
	}
}
