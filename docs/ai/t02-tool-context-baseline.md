# T02 工具上下文基线与路由验收

日期：2026-09-02
分支：`ai-gongju-shangxiawen`
证据类型：`fixture`

## 目标与范围

本步骤量化模型首轮可见工具上下文，复用既有 Capability Registry、工具短名单和确定性路由。
只增加脱敏度量、fixture 验收和报告口径；不变更模型、Prompt、RAG、工具业务语义、Grant、subject 校验或生产配置。

## 记录口径

Runtime 在持久化的 `retrieval.completed` 事件中记录以下字段：

- `registered_tool_count`：当前注册表中的工具总数；
- `model_visible_tool_count`：实际发送到当前 Provider 请求的工具数；
- `tool_schema_bytes`：模型可见 `ToolDefinition` 集合序列化后的 UTF-8 字节数；
- `tool_schema_token_estimate`：用于跨提交趋势比较的近似 token 数；并非 Provider billing usage；
- `tool_routing_mode`：固定枚举路由类型；
- `tools_suppressed_by_verified_policy_rag`：已核验证据使本轮无需工具时为 `true`；
- `tool_schema_measurement_available`：Schema 序列化是否成功。

事件不保存问题文本、模型答案、工具 Schema 原文、工具参数、Grant、身份字段或任何个人数据。实际输入 token 和费用继续只以 Provider 的 `usage.settled` 为准；两类事件以同一 `run_id` 关联。

## Fixture 验收

`TestMeasureToolContextQuantifiesScopedDeterministicRoutes` 使用固定工具定义覆盖：

| 场景 | 路由后可见工具 | 必须满足 |
| --- | --- | --- |
| 公共政策问答 | 公开政策、校历、食堂、公开竞赛工具 | 不出现个人学业、课表或个人计划工具 |
| 个人学业分析 | `academic_get_risk_analysis` | 只保留确定性学业入口 |
| 课表空闲时间 | `schedule_get_availability` | 不能只依赖模型猜测 |
| 个人竞赛计划 | `competition_get_my_plan` | 只保留个人计划入口 |

测试比较每个 scoped 场景与“全部注册工具可见”的 fixture 基线，要求总工具数和总 Schema token 近似值均下降。其结论仅证明本地路由契约，不代表 staging 或线上配置，因为生产是否启用 Unified Agent、注册哪些工具以及实际 Provider usage 均尚未只读核验。

本次 fixture 结果（2026-09-02）：注册工具基线为 8 个，四类场景平均可见工具数为 1.75 个；Schema token 近似值由基线 322 降至平均 72。该比例只用于本地路由趋势比较，不外推为线上 token 或费用节省。

## 验证命令

在 `server/` 目录执行：

```text
go test ./internal/ai -run 'TestMeasureToolContext|TestToolContextMetricsAreTraceSafeAndAggregated|TestRouteModelTools|TestAgentBlackBoxScenarioMatrix' -count=1
go test ./internal/ai -count=1
go test ./...
go vet ./...
```

## 停止条件与后续门禁

- 若指标显示某一真实路由持续暴露无关工具或遗漏必需工具，先按单一失败类别补充独立 fixture，再决定是否调整短名单规则；不得把模型、Prompt、RAG 或权限改动混入该提交。
- 公共问题出现个人工具、个人工具绕过 Grant/subject 校验、课表类问题未保留确定性入口，均为阻断性回归。
- 生产基线仍须等待负责人明确的“仅生产只读核验”授权、隔离测试账号和安全凭据注入方式；不执行 SSH、真实请求、配置修改、服务重启、灰度、发布或 GitHub 推送。
