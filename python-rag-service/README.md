# Python RAG Service

该服务只暴露给 Go 后端的内部网络。Go 保留 JWT、配额、预算、客户端 SSE、来源二次校验与结算；Python 使用 LCEL Runnable 编排政策 RAG。T02 的基础检索器会安全返回证据不足，后续 T04 再替换为只读混合检索器。

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
