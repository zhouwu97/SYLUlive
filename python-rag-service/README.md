# Python RAG Service

该服务只暴露给 Go 后端的内部网络。Go 保留 JWT、配额、预算、客户端 SSE、来源二次校验、结算和知识写入事务；Python 使用 LCEL Runnable 编排政策 RAG，并使用 LangChain `Document`、`TextSplitter`、`Embeddings` 完成政策分块和向量化。

`/internal/rag/knowledge/chunk` 返回展示正文、检索专用 embedding 文本和可审计 metadata。两者严格分离：数据库 chunk 正文不混入标题、部门或别名。embedding 响应报告模型名、模型版本和真实维度；服务不补零、不截断向量。改变模型或维度前必须先执行 `server/sql/20260727_ai_langchain_ingestion.sql`，并通过模型注册表与影子向量索引完成切换。

## 锁定兼容矩阵

| 组件 | 锁定版本 | 兼容边界 |
| --- | --- | --- |
| Python | 3.11 | Docker 与 CI 基准版本 |
| FastAPI | 0.116.1 | Pydantic v2 |
| Pydantic | 2.11.7 | 禁止 v1 compatibility imports |
| langchain | 0.3.27 | 仅使用 LCEL，不使用弃用 Chain 类 |
| langchain-core | 0.3.72 | `Runnable`、`Document`、`BaseRetriever`、Prompt |
| langchain-openai | 0.3.28 | OpenAI-compatible ChatModel |
| langchain-text-splitters | 0.3.9 | T03 使用 |
| psycopg | 3.2.9 | 后续只读 PostgreSQL 检索 |

升级时必须在单独变更中同时更新锁定版本、离线契约测试和本表。不得只升级单个 LangChain 包；先检查弃用警告，再运行 Python 全量测试及 Go `RAGClient|LangChain|Runtime` 契约测试。测试默认注入 Fake Retriever 和 Fake ChatModel，不配置 Provider、不下载模型、不访问网络。

Provider 地址只从部署环境读取，并且必须命中 `RAG_PROVIDER_ALLOWED_BASE_URLS` 白名单。请求体不能覆盖 Provider、Base URL、模型或密钥。默认不启用 LangSmith。
