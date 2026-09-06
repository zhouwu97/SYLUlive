# Python RAG Service

该服务只暴露给 Go 后端的内部网络。Go 保留 JWT、配额、预算、客户端 SSE、来源二次校验、结算和知识写入事务；Python 使用 LCEL Runnable 编排政策 RAG，并使用 LangChain `Document`、`TextSplitter`、`Embeddings` 完成政策分块和向量化。

`/internal/rag/knowledge/chunk` 返回展示正文、检索专用 embedding 文本和可审计 metadata。两者严格分离：数据库 chunk 正文不混入标题、部门或别名。embedding 响应报告模型名、模型版本和真实维度；服务不补零、不截断向量。改变模型或维度前必须先执行 `server/sql/20260727_ai_langchain_ingestion.sql`，并通过模型注册表与影子向量索引完成切换。

## 锁定兼容矩阵

| 组件 | 锁定版本 | 兼容边界 |
| --- | --- | --- |
| Python | 3.11 | Docker 与 CI 基准版本 |
| FastAPI | 0.141.1 | Pydantic v2 |
| Pydantic | 2.12.5 | 禁止 v1 compatibility imports |
| langchain | 1.4.0 | 仅使用 LCEL，不使用弃用 Chain 类 |
| langchain-classic | 1.0.8 | 仅承载 `ContextualCompressionRetriever` 兼容模块 |
| langchain-core | 1.6.1 | `Runnable`、`Document`、`BaseRetriever`、Prompt |
| langchain-openai | 1.6.0 | OpenAI-compatible ChatModel |
| langchain-text-splitters | 1.1.2 | T03 使用 |
| psycopg | 3.2.9 | 后续只读 PostgreSQL 检索 |

升级时必须在单独变更中同时更新锁定版本、离线契约测试和本表。不得只升级单个 LangChain 包；先检查弃用警告，再运行 Python 全量测试及 Go `RAGClient|LangChain|Runtime` 契约测试。测试默认注入 Fake Retriever 和 Fake ChatModel，不配置 Provider、不下载模型、不访问网络。

Provider 地址只从部署环境读取，并且必须命中 `RAG_PROVIDER_ALLOWED_BASE_URLS` 白名单。请求体不能覆盖 Provider、Base URL、模型或密钥。默认不启用 LangSmith。

## 结构化政策生成与引用

生产生成链版本为 `campus-assistant-release-v6`，事件契约版本为 `1.2`。LCEL 链使用
`ChatPromptTemplate`、LangChain `BaseChatModel`、`PydanticOutputParser(PolicyAnswer)` 和
`astream_events(version="v2")`。模型只看到查询计划、最多 8 条历史消息和 rerank 后的
有限证据；证据使用请求内临时编号 `R1`、`R2`，不向模型暴露数据库分块 ID。

Python 会确定性校验临时引用是否存在、引用原文是否为证据子串、计算断言是否出现在引文中，
以及现行/历史规则是否交叉引用。历史规则必须附带“并非当前口径”和教务系统/当期通知核验提示。
校验后才把临时编号转换成公开 `[1]`、`[2]`；原始模型 JSON 不进入对外 token 流。
Go 在完成前再按请求 ID、document/chunk 对、数据库发布状态和有效期重建白名单，来源撤销、
伪造编号或文档不匹配都会整条降级为可靠拒答。来源卡按 `document_id` 聚合 citation 和 locator，
客户端不显示裸分块 ID。

## T09 本地观测与发布门禁

生产链通过本地 Callback 记录链名/版本、HMAC 查询摘要、计划类型、候选数、四路召回耗时、
retrieval/rerank/generation/引用校验/端到端耗时、门禁、usage 和降级模式。指标只经内部鉴权的
`GET /internal/rag/metrics` 暴露，并且不保存完整问题、历史、正文、Prompt、答案、JWT 或密钥。
生产应设置独立的 `RAG_OBSERVABILITY_HASH_SECRET`，让多副本摘要可聚合；不得复用 Provider Key。

`RAG_ALLOW_LANGSMITH=false`、`LANGCHAIN_TRACING_V2=false` 与 `LANGSMITH_TRACING=false` 是默认值。
仅设置 LangSmith 自身变量不能绕过前置门禁。当前发布只验收 `local_only` 指标，任何外发 Trace
都必须另行完成数据分级、脱敏、采样和出境评审。

独立回滚开关为 `RAG_RETRIEVER_ENABLED`、`RAG_RERANKER_ENABLED`、
`RAG_GENERATION_ENABLED`、`RAG_SHADOW_INDEX_ENABLED`、`AI_LANGCHAIN_RAG_ENABLED` 与
`AI_LEGACY_RAG_ENABLED`。账号按稳定 HMAC 分桶执行 LangChain 灰度，顺序只能是内部账号、5%、
20%、50%、100%。完整部署、压测、演练和二进制回滚步骤见
[`docs/ai/t09-langchain-rag-release-runbook.md`](../docs/ai/t09-langchain-rag-release-runbook.md)。

ChatModel 仍使用现有 OpenAI-compatible Provider，超时上限 120 秒、重试 1 次，输出上限由
`RAG_PROVIDER_MAX_OUTPUT_TOKENS` 控制（默认 1600，硬上限 4096）。本链不使用 Agent、
Tool Calling、LangGraph 或第二个模型裁判。

## 混合召回

`PolicyQueryPlanner` 是政策意图、同义词扩展、历史策略和版本边界的唯一生产实现。Python 生产链通过 `HybridPolicyRetriever(BaseRetriever)` 同时启动精确、PostgreSQL FTS、向量和 trigram 四路召回；trigram 结果只在精确与 FTS 候选不足时进入加权 RRF。融合后先执行现行正式文件优先级，再按文档和章节去重，返回的 `Document.metadata` 包含不带问题正文的计划摘要、各通道分数、内容哈希、版本和 locator。

生产环境必须设置 `RAG_DATABASE_DSN`，且账号只能继承 `shenliyuan_rag_reader`。先执行 `server/sql/20260727_ai_langchain_retrieval.sql`，再由部署管理员创建登录角色并强制默认只读：

```sql
CREATE ROLE shenliyuan_rag_runtime LOGIN PASSWORD '<由密钥系统生成>'
    IN ROLE shenliyuan_rag_reader;
ALTER ROLE shenliyuan_rag_runtime SET default_transaction_read_only = on;
```

服务启动时会核验三张检索表具备 `SELECT` 且不具备 `INSERT/UPDATE/DELETE/TRUNCATE`；不满足时 `policy_database=false`，生产查询稳定失败关闭。每个通道还会在只读连接上设置 `statement_timeout`，默认由 `RAG_RETRIEVAL_CHANNEL_TIMEOUT_SECONDS=2.5` 控制。

## Reranker 与相关性门禁

`PolicyReranker(BaseDocumentCompressor)` 与 `HybridPolicyRetriever` 通过
`ContextualCompressionRetriever` 组合在 LCEL 链内。压缩器最多接收 20 个候选，稳定
去重后写入 `rerank_score`、模型名、模型版本和原始排名。`RunnableBranch` 仅在至少一条
成功重排的证据满足 `score >= RAG_RERANKER_RELEVANCE_THRESHOLD` 时调用 ChatModel；空候选、
超时、网络错误、响应长度错误或非有限分数均保留融合顺序并标记
`degraded_modes=rerank`，但会在生成前失败关闭。
CrossEncoder 使用 `PolicyQueryPlanner.retrieval_query` 中的纠错与领域同义词，候选中的
英文 `document_type` 先转换为版本化中文标签；原问题仍用于召回和生成，不会被扩展词替换。
同步模型推理复用受 `RAG_MAX_CONCURRENCY` 限制的实例级线程池，超时后不会按请求无界
增加后台线程。

Reranker 独立开关默认为关闭。`RAG_RERANKER_ENABLED=true` 只启用链路，不授予下载权限；
只有同时设置 `RAG_RERANKER_ALLOW_MODEL_DOWNLOAD=true` 才允许 FastEmbed 下载缺失模型，
否则强制 `local_files_only`。优化后的 BGE 在当前 40 条 T01 集合上通过门禁与 Recall@5
目标，但校准和评测使用了同一数据集，生产环境仍不得仅因该结果开启开关。阈值同时绑定
模型、查询策略和文档类型标签版本，任一项变化都必须重新校准。

默认离线校准不读取模型缓存或网络：

```powershell
python -m app.evaluation --data ..\server\testdata\ai_eval --k 5 --calibrate-reranker
```

真实模型比较必须显式开启；下载还需要第二个独立开关：

```powershell
python -m scripts.compare_rerankers --live --model BAAI/bge-reranker-base
python -m scripts.compare_rerankers --live --allow-model-download --model BAAI/bge-reranker-base
```

完整指标与生产启用结论见 `docs/ai/t05-langchain-reranker-gate-report.md`。
