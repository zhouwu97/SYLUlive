# T06 LangChain 政策生成与结构化引用验收记录

更新时间：2026-07-28

## 实现结论

- 链版本：`shenliyuan_policy_rag / answer-citations-v3`
- 事件 Schema：`1.1`
- 生成组件：`ChatPromptTemplate`、LangChain `BaseChatModel`、
  `PydanticOutputParser(PolicyAnswer)`、LCEL `RunnableBranch`、`astream_events(v2)`
- 模型边界：单个 OpenAI-compatible ChatModel；未使用 Agent、Tool Calling、LangGraph 或第二模型裁判
- Python 校验：临时引用白名单、引用原文子串、计算断言、现行/历史交叉引用及历史边界提示
- Go 校验：请求 ID、document/chunk 对、当前发布状态、有效期、公开数字引用和来源聚合
- 客户端：答案只展示 `[1]` 等公开编号，来源卡按文档展示多个引用编号与 locator

## 关键回归

| 场景 | 预期 |
| --- | --- |
| 补考现行/历史并存 | 历史 D/F、绩点 1/0 与现行重修口径分区展示，并要求按教务系统或当期通知核验 |
| 无证据的成绩合成比例 | Python 确定性校验拒绝，最终只返回可靠拒答 |
| 模型伪造临时引用 | Python 返回 `citation_rejected`，不暴露模型原答案 |
| Python 返回后来源被撤销 | Go 最终发布状态复核移除来源，整条回答降级为可靠拒答 |
| 同文档多个分块 | Go 按 `document_id` 合成一张来源卡，聚合 citation 与 locator |
| 裸分块 ID | Go 旧引用转换为公开编号，Flutter 展示层另有防御性过滤 |

## 验收结果

- Python：`python -m pytest tests -q`，67 项通过。
- Go AI：`go test ./internal/ai`，通过。
- Go Handler：`go test ./internal/handlers -run "AI|Source|Knowledge"`，通过。
- Flutter：`flutter test --no-pub test/models/ai_run_event_test.dart test/widgets/ai`，8 项通过。
- 固定评测：43/43 通过；Recall@5 = 1，MRR = 1；引用合法率、拒答准确率、
  `must_contain` 和 `must_not` 命中率均为 1。
- 差异检查：`git diff --check` 通过，仅报告工作区既有的 LF/CRLF 转换提示。

## 交付信息

- 任务：T06“使用 LangChain 实现政策生成与结构化引用”。
- 当前分支：`diaofenyuan`；本次未创建提交。
- 数据库迁移：无。
- 新增配置：`RAG_PROVIDER_MAX_OUTPUT_TOKENS=1600`，允许范围 128 至 4096。
- 兼容性：事件 Schema 从 `1.0` 升级到 `1.1`，Python 与 Go 必须作为同一发布单元升级。
- 已知限制：结构化答案通过校验后才一次性发送公开 token，因此不会逐字展示模型原始 JSON；
  这是阻止未经校验内容泄露到客户端所必需的行为。

## 回滚

保持 `AI_LANGCHAIN_RAG_ENABLED=false` 可回到旧 Go 路径。协议升级同时修改了 Python 与 Go，
灰度时必须作为同一发布单元部署；不得只升级其中一侧。回滚不涉及数据库迁移。
