# SYLUlive Pure Capability MCP

本目录是与 `server` 分离的 MCP 适配器。它把受控的 Agent capability 映射为 MCP tools，再转发到主服务的 `/internal/mcp/*` 事实接口。

## 安全边界

- MCP 适配器不保存 Agent 状态、不调用 LLM，也不接受 `user_id`、JWT 或学校 Cookie 作为工具参数。
- 每个请求必须携带当前 Run 的 opaque Grant；主服务负责校验 Grant 的 scope、subject、有效期和调用预算。
- 公共能力只能读取公共政策、公开校园信息和经过治理的竞赛数据。
- `academic.summary`、`schedule.free_windows`、`schedule.validate_plan` 是个人能力，只有 Grant 明确授权时才可调用；subject 从 Grant 恢复，调用者不能伪造用户身份。
- 个人教务数据不会因为 MCP 存在就变成公共数据；相关数据来源、授权范围和留存规则以主服务与隐私台账为准。

## 启动

先启动主服务，再启动本目录：

```powershell
$env:SYLULIVE_INTERNAL_URL = "http://127.0.0.1:8080"
go run .\cmd\sylulive-mcp -http :8091
```

Streamable HTTP 请求使用：

```text
Authorization: Bearer g_<run-scoped-token>
```

stdio 仅用于明确绑定单个本地 Run：

```powershell
$env:SYLULIVE_MCP_GRANT = "g_<run-scoped-token>"
go run .\cmd\sylulive-mcp -stdio
```

## 暴露能力

公共/治理能力：`system.status`、`policy.search`、`policy.sources`、`competition.search`、`competition.details`、`competition.governed_context`、`competition.verify`、`competition.compare`。

个人授权能力：`academic.summary`、`schedule.free_windows`、`schedule.validate_plan`。

工具清单和后端路径以 [`internal/mcp/server.go`](./internal/mcp/server.go) 为准。外部 MCP 集成还需要满足主服务的白名单、传输和发布开关要求。

## 验证

```powershell
go test ./...
```
