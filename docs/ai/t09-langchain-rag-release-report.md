# T09 LangChain RAG 发布门禁报告

验收日期：2026-07-28  
分支：`diaofenyuan`  
基线提交：`a52f0d8e`  
结论：代码与本地自动化门禁通过；生产发布门禁为 **NO-GO**，不得切换生产全量开关。

## 交付结果

- LCEL 链版本为 `observability-release-v5`，本地 Callback 指标覆盖 chain/version、查询 HMAC 摘要、计划类型、候选数、四路召回、retrieval、rerank、generation、引用校验、端到端、门禁、usage 和降级模式。
- 指标只通过内部 Token 保护的 `/internal/rag/metrics` 暴露，不保存问题、历史、正文、Prompt、答案、JWT、密钥或 DSN。
- `RAG_ALLOW_LANGSMITH=false`、`LANGCHAIN_TRACING_V2=false`、`LANGSMITH_TRACING=false` 为默认配置，未向 LangSmith 发送数据。
- Go 支持稳定账号 HMAC 分桶，灰度顺序由工具限制为 `off -> internal -> 5 -> 20 -> 50 -> 100`；旧 Go 路径在观察窗口默认保留。
- retriever、reranker、generation、影子索引和旧 Go 路径均有独立回滚开关。
- 端到端、压测和灰度工具默认 dry-run；真实请求、状态写入和额度耗尽均需独立确认短语。
- 部署 Runbook 已覆盖 Python 扩缩容、模型缓存、数据库只读账号、影子索引、灰度证据、服务关闭、旧路径、知识撤销、旧索引及二进制回滚。

## 验收命令

| 命令 | 结果 |
| --- | --- |
| `server: go test ./...` | PASS |
| `server: go build ./...` | PASS |
| `server: go run ./cmd/shenliyuan-ai-eval` | PASS，43/43 |
| `python-rag-service: python -m pytest tests -q` | PASS，83 passed，1 条第三方弃用 warning |
| `client: flutter test --no-pub` | PASS，831 tests |
| `client: flutter analyze --no-pub --no-fatal-warnings --no-fatal-infos` | PASS，0 error；432 条存量 warning/info |

离线评测结果：Recall@5 `1.0`、MRR `1.0`、must-contain `1.0`、must-not `1.0`、拒答准确率 `1.0`、引用合法率 `1.0`，v0.6 核心 19 条全部通过。

补充检查：Python `compileall`、PowerShell Parser、`gofmt -d`、`git diff --check`、T09 端到端 dry-run、压测 dry-run和灰度 dry-run均通过，三个工具均未发送请求或写入灰度状态。

## 最终发布门禁

| 门禁 | 结论 | 证据或缺口 |
| --- | --- | --- |
| T01 达到统一质量目标 | FAIL | 当前共享评测集为 43 条，未达到不少于 100 条；现有 43 条指标全部通过 |
| 生产请求经过版本化 LCEL | 待授权/未执行 | 本地链路和指标自动化通过，缺少生产样本证据 |
| Go、Python、Flutter 与静态分析 | PASS | 全部验收命令退出码为 0，无静态分析 error |
| 生产影子索引对比 | 待授权/未执行 | 未覆盖或切换生产索引 |
| LangChain 服务关闭演练 | 待授权/未执行 | 未操作生产副本 |
| 旧 Go 路径回退演练 | 待授权/未执行 | 仅完成配置、分桶和工具自动化测试 |
| 知识撤销与恢复演练 | 待授权/未执行 | 未变更生产知识 |
| 旧索引恢复演练 | 待授权/未执行 | 未变更生产读取版本 |
| 无证据问题可靠拒答 | PASS（本地） | fixture 拒答准确率 100%，恶意知识指令被隔离 |
| `internal -> 5 -> 20 -> 50 -> 100` 实际发布 | 待授权/未执行 | 工具阻止跳阶段，未写生产全量开关 |
| MCP、Agent、Tool Calling 非前置 | PASS | 本次实现未引入这些能力 |

## 发布限制

当前没有生产 JWT、管理员 JWT、生产压测授权、灰度变更授权或批准的门禁阈值，因此未执行真实生产端到端请求、生产压测、影子索引切换、服务关闭、知识撤销、旧索引恢复和实际灰度推进。真实 p50/p95/p99、吞吐、错误率和成本只能在获批的隔离/灰度环境采集，不能用 dry-run 或 fixture 冒充。

在扩展评测集达到 100 条、补齐关键结论一致率的独立证据，并完成上述生产演练前，`AI_LANGCHAIN_RAG_ROLLOUT_PERCENT` 不得推进到下一阶段，更不得直接设置为 `100`。
