# Agent Regression Scenario Suite v1.1

这一层建立在 `internal/ai/eval` 的 68 个 Kernel contract case 之上，专门验证真实 Agent 执行链：

```text
scripted Provider decision
→ AgentOrchestrator
→ Capability selection
→ ToolRegistry
→ fake tool backend
→ Observation
→ Replan
→ Action proposal
→ fake calendar commit
→ read-back verify
```

Provider 和外部业务仓库是可控 fake；Orchestrator、Capability selection、ToolRegistry、ToolCall 持久化幂等、Observation 和 Replan 使用真实实现。场景不会连接线上服务，也不会产生真实用户副作用。

当前包含 21 个 deterministic scenario，包含 4 个 Action commit、3 个 verified commit、双确认幂等和 postcondition failure。场景 baseline 独立于 Kernel baseline：

```text
baseline_scenario.json
```

执行入口：

```text
cd server
go test ./internal/ai/eval/scenario -count=1 -v
go run ./cmd/shenliyuan-ai-regression -suite scenario -baseline internal/ai/eval/scenario/baseline_scenario.json
go run ./cmd/shenliyuan-ai-regression -suite all
```

`model` 行为评测仍然不进入 deterministic scenario CI；它使用上层 `ModelBehaviorCase` 统计接口，后续再接 Provider。
