# Real User Gray v1

## Scope

Real User Gray v1 只闭合线上使用质量、效率、可靠性和安全性观测，不引入 Explicit Memory、Agent V6、Orchestrator 重构或 `_mcp` 业务逻辑。

客户端反馈只上传结构化枚举。负向反馈的可选说明最多 200 个 Unicode 字符，服务端只保存 `detail_hash` 与 `detail_length`，不保存原文。

## Signals

- `answer.useful`：用户主动点“有帮助”。
- `answer.first_useful`：回答首段达到最小可读长度，记录 TTUA。
- `run.first_activity`：首个可展示 Agent activity，记录 TTFA。
- `run.rephrased` / `possible_user_correction`：用户在短窗口内重述或出现纠正措辞，仅作趋势信号。
- `run.abandoned`：用户主动取消 Run。

客户端展示的 Agent activity 只来自已脱敏的状态标题、工具阶段和结果状态，不展示内部推理过程。

## Retention and deletion

默认保留 Shadow 事件 14 天、反馈/失败分类事件 60 天，可通过 `AI_SHADOW_TRACE_RETENTION_DAYS`（1–90）和 `AI_FAILURE_TRACE_RETENTION_DAYS`（7–180）调整。进程启动后每 6 小时执行清理；也可调用 Runtime 的保留策略入口执行一次性清理。

用户可以删除自己的全部观测数据：`DELETE /api/ai/observability`；也可以按 Run 删除：`DELETE /api/ai/runs/:id/observability`。这两个接口不删除会话正文、Run 状态或工具结果。

## Gray dashboard and kill switch

管理员接口：`GET /api/admin/ai/gray-dashboard?days=7`。返回聚合指标、P0/P1 告警和止损路径，不返回 prompt、回答正文、user hash 或工具原文。

P0 红线：权限绕过、错误动作成功、跨用户污染。P1 默认阈值：动作回读失败率 5%、降级 Run 率 20%、FAST→NORMAL 升级率 40%、用户纠正率 15%、P95 TTUA 8000ms。

止损顺序：先设 `AI_AGENT_ACTIONS_ENABLED=false`，必要时设 `AI_AGENT_PERSONAL_DATA_ENABLED=false`，仍异常则设 `AI_AGENT_ENABLED=false`，完成部署后在 dashboard 确认告警归零。

## Regression workflow

`run.failure_classified` 只产生脱敏的 `regression.scenario_candidate`（稳定 case ID、trace ID、失败枚举）。管理员通过：

- `GET /api/admin/ai/regression-candidates`
- `POST /api/admin/ai/regression-candidates/:run_id/review`，body 为 `{"case_id":"...","decision":"approved|rejected"}`

审核事件进入 append-only Trace；approved 候选由人工补齐可复现输入后复制到 `server/internal/ai/eval/scenario`，再执行 scenario suite。线上 Trace 不自动写入回归场景，避免个人数据污染 CI。

## CI gate

```text
Regression Gate: deterministic=68/68 scenario=33/33 total=101/101
```

该行由 `go run ./cmd/shenliyuan-ai-regression -suite all` 输出；JSON 模式同时返回 `gate.deterministic_cases`、`gate.scenario_cases`、`gate.total_cases` 及对应 passed 字段。
