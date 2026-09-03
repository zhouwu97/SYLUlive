# T01 真流式回答本地验收报告

## 结论

状态：`preflight_pass`（证据类型：`fixture`）。

本地契约确认：Provider 尚未发送完成事件时，Go Runtime 已向在线订阅者广播首个 `answer.delta`；完成后最终检查点与增量内容一致，在线增量未写入事件表。现有工具轮回滚、周期 checkpoint 和 `Last-Event-ID` 回放回归也通过。

## 已执行命令

工作目录分别为 `server/`、`client/` 与仓库根目录：

```text
# server/
go test -race ./internal/ai -run TestRuntimeBroadcastsFirstDeltaBeforeProviderCompletion -count=10
go test ./internal/ai -run 'TestRuntimeBroadcastsFirstDeltaBeforeProviderCompletion|TestRuntimeToolLoopStreamsDeltasAndRollsBackBetweenRounds|TestRuntimeToolLoopPureToolRoundEmitsNoDeltaOrRollback|TestAnswerStreamEmitterPersistenceAndBroadcast' -count=10
go test ./...
go vet ./...
# client/
flutter test --no-pub test/providers/ai_assistant_provider_test.dart test/models/ai_run_event_test.dart
# 仓库根目录
python -m pytest scripts -q
git diff --check
```

结果：上述命令均通过；客户端定向测试 29 项通过，脚本测试 24 项通过。

## 尚未证明

- staging/线上 HTTP SSE 首字时间、客户端逐字渲染、弱网重连和慢客户端表现；
- 当前生产二进制是否包含该实现，以及生产开关、模型、RAG、MCP 和知识库版本；
- 取消、引用校验、额度结算在真实部署中的端到端时序。

## 门禁与下一步

在获得负责人明确的“仅生产只读核验”授权、隔离测试账号和安全凭据注入方式前，不执行 SSH、真实请求、配置修改、服务重启、灰度、发布或 GitHub 推送。若线上二进制缺少真流式能力，后续只发布流式能力，不与模型、Prompt、RAG 或工具路由变更混合。
