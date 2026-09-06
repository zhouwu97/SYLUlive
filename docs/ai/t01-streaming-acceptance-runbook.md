# T01 真流式回答本地验收 Runbook

## 目标

验证 Provider 产生首个文本增量后，Go Runtime 会立即广播 `answer.delta`，而不是等到 Provider 完成后一次性发送整段回答。工具轮回滚、周期 checkpoint、取消和 `Last-Event-ID` 回放沿用既有契约，不在本步骤混入模型、Prompt、RAG 或配置变更。

## 本地验收

在 `server/` 目录执行：

```text
go test ./internal/ai -run TestRuntimeBroadcastsFirstDeltaBeforeProviderCompletion -count=1
go test ./internal/ai -run 'TestRuntimeToolLoopStreamsDeltasAndRollsBackBetweenRounds|TestAnswerStreamEmitterPersistenceAndBroadcast' -count=1
go test ./internal/handlers -run TestAIEventsReplaysPersistedEventsAfterLastEventID -count=1
```

验收必须同时满足：

- Provider 尚未发送完成事件时，订阅者已收到首个 `answer.delta`；
- 在线 `answer.delta` 不写入事件表，最终答案只通过完成态/检查点持久化；
- 工具轮前的预文本只通过持久化 `answer.rollback` 撤销，不重复补发整段文本；
- 重连从 `Last-Event-ID` 之后回放，不重复旧事件。

## 证据边界

本 Runbook 产生的结果是 `fixture` 证据，只能证明本地契约。它不能替代 staging 的真实客户端渲染、弱网重连、慢客户端或线上二进制核验；线上报告必须单独标记为 `online`，并使用隔离测试账号与脱敏时序数据。

## 失败即停与回滚

若首个 `answer.delta` 只能在完成事件后出现、客户端出现丢字/重复/抖动、取消或回放语义回归，停止 T01 发布，不调整模型、RAG、工具短名单或公网配置。代码候选应回退到上一已验证提交；生产发布仍需独立授权、保留旧二进制摘要和可执行回滚步骤。
