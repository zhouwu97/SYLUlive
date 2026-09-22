package handlers

import (
	"context"
	"encoding/json"
	"net/http"
	"testing"

	"shenliyuan/internal/services"
)

// forceSecurityEventWriteFailures 制造「表在、库在，但事件写不进去」的状态：
// 用一个立即过期的 context 走真实写入路径，让运行态由失败计数决定，而不是靠假数据糊过去。
func forceSecurityEventWriteFailures(t *testing.T, service *services.SecurityEventService, times int) {
	t.Helper()
	for i := 0; i < times; i++ {
		ctx, cancel := context.WithCancel(context.Background())
		cancel()
		err := service.RecordContext(ctx, services.SecurityEventInput{
			EventType: "login_bruteforce", Severity: "high",
			Route: "/api/login", Method: http.MethodPost, ClientIP: "203.0.113.9",
			TargetType: "account", TargetValue: "student@example.com",
		})
		cancel()
		if err == nil {
			t.Fatalf("第 %d 次写入应当失败", i+1)
		}
	}
}

func decodeOverview(t *testing.T, body []byte) map[string]interface{} {
	t.Helper()
	var payload map[string]interface{}
	if err := json.Unmarshal(body, &payload); err != nil {
		t.Fatalf("解析总览响应失败: %v\n%s", err, body)
	}
	return payload
}

// SEC-05：只有事件写入失败时，安全中心总览与 /health 必须报同一件事。
func TestPublicHealthAndOverviewAgreeOnEventWriteFailure(t *testing.T) {
	_, db := newSecurityOverviewTestHandler(t)
	service := services.NewSecurityEventService(db, "test-secret", nil)
	handler2 := NewSecurityAdminHandler(db, service)
	handler2.SetProtectionConfig(true, nil, "")

	runtimeBefore, _, _ := SecurityPublicHealthPayload(service, true, true, true)
	if runtimeBefore != "ok" {
		t.Fatalf("干净状态下探针应为 ok，实际 %q", runtimeBefore)
	}

	forceSecurityEventWriteFailures(t, service, 2)

	status, httpStatus, fields := SecurityPublicHealthPayload(service, true, true, true)
	probeValue, ok := fields["security_event_collection"]
	if !ok {
		t.Fatalf("探针必须暴露事件采集运行态，实际字段: %v", fields)
	}

	recorder := runSecurityOverview(t, handler2, context.Background())
	if recorder.Code != http.StatusOK {
		t.Fatalf("总览应正常返回，实际 %d: %s", recorder.Code, recorder.Body.String())
	}
	overviewValue := decodeOverview(t, recorder.Body.Bytes()[:])["protection"].(map[string]interface{})["security_event_collection"]

	if probeValue != overviewValue {
		t.Fatalf("同一事实给出两种结论：探针 %v，安全中心 %v", probeValue, overviewValue)
	}
	if probeValue == services.SecurityLayerReady || probeValue == services.SecurityLayerUnknown {
		t.Fatalf("连续写入失败后不应仍报 %v", probeValue)
	}
	if status != "degraded" || httpStatus != http.StatusServiceUnavailable {
		t.Fatalf("事件写入失败必须让探针降级，实际 %q/%d", status, httpStatus)
	}
	if failures, _ := fields["security_event_write_consecutive_failures"].(int); failures < 2 {
		t.Fatalf("探针应带上连续失败次数供定位，实际 %v", fields["security_event_write_consecutive_failures"])
	}
}

// 反向对照：进程启动后还没写过事件时是 unknown，不能算故障，否则每次重启都误报。
func TestPublicHealthTreatsUnprobedCollectionAsUnknown(t *testing.T) {
	_, db := newSecurityOverviewTestHandler(t)
	service := services.NewSecurityEventService(db, "test-secret", nil)
	status, httpStatus, fields := SecurityPublicHealthPayload(service, true, true, true)
	if fields["security_event_collection"] != services.SecurityLayerUnknown {
		t.Fatalf("未探测过应报 unknown，实际 %v", fields["security_event_collection"])
	}
	if status != "ok" || httpStatus != http.StatusOK {
		t.Fatalf("unknown 不应把探针打成降级，实际 %q/%d", status, httpStatus)
	}
}

// 连续失败到阈值后必须升级为 unavailable（探针与总览同一判据）。
func TestPublicHealthEscalatesAfterRepeatedWriteFailures(t *testing.T) {
	_, db := newSecurityOverviewTestHandler(t)
	service := services.NewSecurityEventService(db, "test-secret", nil)
	forceSecurityEventWriteFailures(t, service, services.SecurityLayerUnavailableAfterFailures)
	status, httpStatus, fields := SecurityPublicHealthPayload(service, true, true, true)
	if fields["security_event_collection"] != services.SecurityLayerUnavailable {
		t.Fatalf("连续 %d 次失败应升级为 unavailable，实际 %v",
			services.SecurityLayerUnavailableAfterFailures, fields["security_event_collection"])
	}
	if status != "degraded" || httpStatus != http.StatusServiceUnavailable {
		t.Fatalf("采集不可用必须降级，实际 %q/%d", status, httpStatus)
	}
}

// SEC-09：公共探针不输出部署配置与来源信息；这些留在受保护的管理接口上。
func TestPublicHealthOmitsDeploymentConfig(t *testing.T) {
	_, db := newSecurityOverviewTestHandler(t)
	service := services.NewSecurityEventService(db, "test-secret", nil)
	_, _, fields := SecurityPublicHealthPayload(service, true, true, true)
	for key := range fields {
		switch key {
		case "trusted_proxy_cidrs", "source_attribution_valid_from", "trusted_proxy_configured":
			t.Fatalf("公共探针不应输出部署配置字段 %q", key)
		}
	}
	// 正向对照：这些配置在管理员总览里仍然可见，收紧的是暴露面而不是可运维性。
	handler := NewSecurityAdminHandler(db, service)
	handler.SetProtectionConfig(true, []string{"10.0.0.0/8"}, "2026-09-01T00:00:00Z")
	recorder := runSecurityOverview(t, handler, context.Background())
	if recorder.Code != http.StatusOK {
		t.Fatalf("总览应正常返回，实际 %d: %s", recorder.Code, recorder.Body.String())
	}
	protection := decodeOverview(t, recorder.Body.Bytes()[:])["protection"].(map[string]interface{})
	if len(protection["trusted_proxy_cidrs"].([]interface{})) != 1 {
		t.Fatalf("管理员总览应继续展示反代网段，实际 %v", protection["trusted_proxy_cidrs"])
	}
	if protection["source_attribution_valid_from"] != "2026-09-01T00:00:00Z" {
		t.Fatalf("管理员总览应继续展示归因生效时间，实际 %v", protection["source_attribution_valid_from"])
	}
}
