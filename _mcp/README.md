# SYLUlive Pure Capability MCP

这是与 `server` 分离的纯能力层适配器。它只把 Agent Contract v5 的语义能力映射为 MCP tools，再转发到主服务的 `/internal/mcp/*` 事实接口；不保存 Agent 状态、不调用 LLM、不接收 `user_id`、JWT 或 Cookie。

## 启动

先启动 `E:\AI\xynewui\server`，再启动本目录：

```powershell
$env:SYLULIVE_INTERNAL_URL = "http://127.0.0.1:8080"
go run .\cmd\sylulive-mcp -http :8091
```

默认使用 Streamable HTTP。每个请求携带当前 Run 的 opaque Grant：

```text
Authorization: Bearer g_<run-scoped-token>
```

stdio 仅用于明确绑定单个本地 Run 的进程，并要求设置 `SYLULIVE_MCP_GRANT`：

```powershell
$env:SYLULIVE_MCP_GRANT = "g_<run-scoped-token>"
go run .\cmd\sylulive-mcp -stdio
```

## 暴露能力

`system.status`、`policy.search`、`policy.sources`、`competition.search`、`competition.details`、`competition.governed_context`、`competition.verify`、`competition.compare`、`academic.summary`、`schedule.free_windows` 和 `schedule.validate_plan`。

Grant 的能力列表、scope、有效期和调用次数由主服务 Control Plane 校验。个人学业/日程能力的 subject 只从 Grant 恢复，工具参数中不能伪造身份。

## 验证

```powershell
go test ./...
```
