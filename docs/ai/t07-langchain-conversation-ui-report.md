# T07 有界多轮上下文与客户端来源体验验收记录

更新时间：2026-07-28

## 实现结论

- 链版本：`shenliyuan_policy_rag / conversation-context-v4`
- 事件 Schema：`1.1`，本任务未改变流事件协议版本。
- Go 会话边界：仅按当前 JWT 用户与当前 conversation 读取已完成 Run，并复核会话、Run、消息三者归属；删除会话、失败 Run、残缺轮次、其他账号和其他会话均不能进入历史。
- Go 历史上限：最近 4 个完整轮次、最多 8 条消息、总计 2400 个 grapheme；单条用户消息最多 300 个 grapheme，单条助手消息最多 600 个 grapheme，省略号计入预算。
- Python 上下文：使用 `ChatPromptTemplate`、`MessagesPlaceholder` 和独立无状态 Query Rewrite Runnable；Python 只处理 Go 传入的有限副本，并再次限制为 4 轮、8 条、2400 字符。
- 查询改写：只对“那实验课呢”等短追问补入最近用户问题；查询规划、召回和 reranker 使用改写查询，生成仍使用有限原始历史。
- 会话所有权：未引入 LangChain Memory，Python 不读取会话数据库，也不持久化历史。
- 输入限制：`AI_MAX_MESSAGE_CHARS` 默认 200，可配置范围为 20 至 300；Runtime、capabilities 与客户端计数和提交校验保持一致。下限 20 仅用于兼容已有部署。
- 来源体验：来源卡展示发布部门、文档状态、生效区间和 locator；折叠标题最多两行，展开后显示完整标题；客户端不展示裸 `chunk_id`。
- 数据边界：未接入个人成绩、课表、体测、二课数据、MCP、Agent 或 Tool Calling。

## 关键回归

| 场景 | 结果 |
| --- | --- |
| “补考成绩怎么算”后追问“那实验课呢” | 召回查询改写为包含上一问题的短追问，命中实践教学环节规则 |
| 其他账号或其他会话存在消息 | Go 查询按用户与 conversation 双重过滤，Python 无法获得越权历史 |
| 最近存在失败或残缺 Run | 不占用最近 4 个有效完整轮次名额 |
| 超长历史 | Go 按 grapheme 硬截断，Python 对副本再次确定性裁剪 |
| 会话已删除 | 历史加载失败关闭，不向 Python 发送已删除会话内容 |
| SSE 断线或用户取消 | 既有取消链路继续传播到 LangChain 请求并释放预留 |
| 来源带 `+08:00` 生效日期 | 客户端按政策日期语义展示，不因时区换算偏移一天 |
| 来源含内部 chunk 标识 | 卡片只展示公开引用编号和 locator，不展示裸 ID |

## 验收结果

- Python：`python -m pytest tests -q`，70 项通过；仅有 1 条 `jieba/pkg_resources` 弃用警告。
- Go：`go test ./internal/ai ./internal/handlers`，全部通过。
- Flutter：`flutter test test/providers/ai_assistant_provider_test.dart test/screens/ai test/widgets/ai`，12 项通过。
- Flutter 静态分析：`flutter analyze --no-fatal-warnings --no-fatal-infos`，退出码 0；仓库仍有 432 条非致命存量 warning/info。
- 差异检查：`git diff --check` 通过，仅有 Git 的 LF/CRLF 工作区提示。

## 交付信息

- 任务：T07“有界多轮上下文与客户端来源体验”。
- 当前分支：`diaofenyuan`；本次未创建提交。
- 数据库迁移：无。
- 配置变化：`AI_MAX_MESSAGE_CHARS` 默认值由 20 调整为 200，合法范围调整为 20 至 300。
- 评测指标变化：本任务未运行需要生产知识库的 live 质量评测；离线短追问与边界回归全部通过。
- 未完成事项：无。

## 风险与回滚

- 上下文增加会提高追问请求的输入 token，但 4 轮、8 条消息和 2400 grapheme 三重上限可控制成本。
- Query Rewrite 采用确定性短追问补全，不新增模型调用；若出现误改写，可回退 Python 链版本到 `answer-citations-v3` 并移除 rewrite 阶段。
- 可将 `AI_MAX_MESSAGE_CHARS` 调回 20 并同步部署 Go 与客户端，恢复旧输入限制。
- 可回退来源 DTO 和 Flutter 卡片字段；本任务没有数据库迁移或线上数据变更。
- 保持 `AI_LANGCHAIN_RAG_ENABLED=false` 可回到旧 Go 路径。Go、Python 与客户端应作为同一发布单元部署，避免 capabilities、链契约和界面不同步。

结论：T07 验收通过，可以进入 T08。
