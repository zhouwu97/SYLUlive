package handlers

import (
	"net/http"

	"shenliyuan/internal/services"
)

// SecurityPublicHealthPayload 组装公共 /health 里的安全摘要，返回整体状态、HTTP 码和字段。
//
// 为什么单独成一个函数：/health 曾经自己就地拼一份「表在不在」的判断，安全中心总览
// 另拼一份「写入真实成败」的，于是事件写入长期失败时看板降级、探针仍然绿色（A11）。
// 两边现在都走 services 的同一套层状态函数，这个函数就是探针侧唯一的出口。
//
// 口径：
//   - unknown（进程启动后还没探测过）只报告事实，不判失败：否则每次重启都会误报；
//   - 封禁查询降级、事件采集不可用才降级整体状态；
//   - 公共端点不输出反代网段、归因生效时间这类部署配置，也不输出来源摘要（SEC-09）。
func SecurityPublicHealthPayload(security *services.SecurityEventService, blockEnabled, eventTableReady, blockTableReady bool) (string, int, map[string]interface{}) {
	event := security.EventCollectionState(eventTableReady)
	block := security.BlockLookupState(blockEnabled, blockTableReady)

	status := "ok"
	httpStatus := http.StatusOK
	// 只有「已经探测出故障」才降级：unknown 表示还没探测过，报告事实但不判定失败，
	// 否则每次重启都会误报。采集 degraded 与 unavailable 都算降级——安全中心已经在报
	// 同一个词，探针慢一档就会造成 A11 描述的「看板红、监控绿」。
	if event.Runtime == services.SecurityLayerDegraded || event.Runtime == services.SecurityLayerUnavailable ||
		block.Runtime == services.SecurityLayerDegraded ||
		block.Runtime == services.SecurityLayerUnavailable {
		status = "degraded"
		httpStatus = http.StatusServiceUnavailable
	}

	fields := map[string]interface{}{
		// *_schema_ready 保留给尚未升级的探针脚本，但它们只是 DDL 事实，
		// 真正代表「这层防护此刻是否在工作」的是下面两个 *_state 字段。
		"security_event_schema_ready": eventTableReady,
		"security_event_collection":   event.Runtime,
		"security_block_enabled":      blockEnabled,
		"security_block_schema_ready": blockTableReady,
		"security_block_lookup":       block.Runtime,
		// 中间件 fail-open 时给出的旧字段名保持不变，值改由同一份层状态推导。
		"security_block_runtime_degraded": block.Runtime == services.SecurityLayerDegraded ||
			block.Runtime == services.SecurityLayerUnavailable,
	}
	if event.Reason != "" {
		fields["security_event_collection_reason"] = event.Reason
	}
	if block.Reason != "" {
		fields["security_block_lookup_reason"] = block.Reason
	}
	if failures, ok := event.Detail["consecutive_failures"]; ok {
		fields["security_event_write_consecutive_failures"] = failures
	}
	return status, httpStatus, fields
}
