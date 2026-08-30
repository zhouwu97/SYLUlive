# Agent Regression Suite v1

这是 Agent Kernel v5 的只读回归层。它不修改 Orchestrator、Goal、Scoped Grant 或业务 Capability，只通过公开 Agent 契约执行 deterministic probe，并输出可长期比较的指标。

## 分类覆盖

| 分类 | Case 数 |
| --- | ---: |
| core | 8 |
| context | 7 |
| permission | 8 |
| planning | 8 |
| replanning | 7 |
| action | 8 |
| recovery | 6 |
| degradation | 6 |
| security | 6 |
| cost | 4 |
| 合计 | 68 |

分类是 `CaseSpec.Category` 的稳定契约，不强制把既有同包测试搬到空目录中。后续如果某一类需要大量 fixture，可以再增加对应子目录；当前所有 deterministic case 已集中注册，避免目录拆分制造重复基线。

## 执行

在 `server/` 目录运行：

```text
go test ./internal/ai/eval -count=1 -v
go run ./cmd/shenliyuan-ai-regression -baseline internal/ai/eval/baseline_deterministic.json
go run ./cmd/shenliyuan-ai-regression -json -baseline internal/ai/eval/baseline_deterministic.json
```

`baseline_deterministic.json` 只读加载，Suite 不会自动覆盖。超过安全阈值、成功率、P95 Tool Calls 或平均 Tool Calls 增长阈值时，CLI 返回非零退出码。仓库保留旧的 `baseline.json` 作为兼容别名。

## Model behavior

在线模型 case 使用 `ModelBehaviorCase` / `RunModelBehaviorSuite`，与 deterministic suite 分开，允许同一 case 重复 3–5 次并按成功率阈值判断。v1 只提供接口，不注册在线模型测试，因此 CI 不依赖 Provider、网络或 token usage。

Provider 可提供 usage 时，外层 runner 应填充 `ModelCalls`、`InputTokens`、`OutputTokens`；当前 deterministic suite 将这些字段保持为 0，表示 unavailable，而不是估算。
