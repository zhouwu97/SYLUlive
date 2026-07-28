# T05 LangChain Reranker 与相关性拒答门禁报告

日期：2026-07-28

## 实现口径

- `PolicyReranker` 实现 LangChain `BaseDocumentCompressor`，最多接收 20 个候选，按
  `(-rerank_score, original_rank)` 稳定排序，并记录模型逻辑名称、版本和原始排名。
- `ContextualCompressionRetriever` 将混合召回与 reranker 组合在 LCEL 生产链内；
  `RunnableBranch` 在证据分数不足时直接返回 `rag_insufficient_sources`，不调用 ChatModel。
- 模型超时、网络错误、分数数量异常、NaN/Inf 或越界分数均回退融合顺序，记录
  `degraded_modes=rerank`，门禁因缺少有效 rerank 分数而失败关闭。
- 同步模型推理使用实例级有界线程池，并继承服务 `RAG_MAX_CONCURRENCY` 上限；超时任务
  不会导致后台线程数量按请求无界增长。
- v2 输入优化只在 CrossEncoder 评分阶段使用 `PolicyQueryPlanner.retrieval_query`，并将
  英文文档类型转换为 `policy-document-type-zh-v1` 中文标签；原问题仍用于召回和生成。
- 链版本从 `hybrid-retrieval-v1` 更新为 `reranker-gate-v2`；Go 事件协议增加 `reranking`
  阶段。

## T01 校准方法

数据唯一来源为 `server/testdata/ai_eval/*.jsonl`：40 条政策用例，其中 36 条可回答、
4 条应拒答，包含 v0.6 关键 19 条。为验证“向量 Top K 非空但无关”的门禁场景，每条
用例从同一 T01 语料构造最多 20 个候选；只把明确属于其他规划域的文档作为干扰项，
不擅自把同域未标注文档当作负样本。阈值按可回答召回率与负例拒答率的平衡目标选择，
边界语义固定为 `score >= threshold`。

## 离线可复现指标

默认 fixture scorer 不下载模型，只用于门禁、排序和阈值算法的确定性回归：

| 指标 | 重排前 | 重排后 |
| --- | ---: | ---: |
| 扩展校准池 Recall@5 | 92.31% | 100% |
| 扩展校准池 MRR | 0.200 | 1.000 |
| v0.6 关键 19 条 Recall@5 | - | 100% |
| v0.6 关键 19 条 MRR | - | 1.000 |
| 门禁准确率 | - | 100% |
| 可回答召回率 | - | 100% |
| 负例拒答率 | - | 100% |

fixture scorer 的校准阈值为 `0.44`。该数值只属于
`policy-domain-overlap-v1`，不能用于真实 CrossEncoder。

## 真实模型对比

初次模型对比显式传入 `--live --allow-model-download` 下载模型；下载后均以 `--live` 和
默认 `local_files_only` 复跑。v2 优化结果由正式比较脚本在禁止下载时复现，未连接数据库、
模型 Provider 或生产服务。

| 模型 | 平衡阈值 | 门禁准确率 | 可回答召回 | 负例拒答 | 全集 Recall@5 / MRR | 关键 19 Recall@5 / MRR |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| MiniLM L12 | 0.996305 | 67.50% | 66.67% | 75.00% | 66.67% / 0.536 | 71.43% / 0.610 |
| BGE 原始问题 | 0.224048 | 92.50% | 91.67% | 100% | 92.31% / 0.904 | 85.71% / 0.921 |
| BGE 规划查询 + 中文类型标签 | 0.689045 | 100% | 100% | 100% | 100% / 0.986 | 100% / 1.000 |

原始输入的失败主要集中在“补考/二考/重修”术语、错别字和双文档证据。复用 T04 查询
规划并中文化类型标签后，BGE 消除了 3 条误拒和 3 条关键排序失败。由于 40 条 T01 数据
同时用于阈值校准和结果评测，该 100% 仍可能存在乐观偏差，不能替代独立留出集。

## 配置与发布结论

- `RAG_RERANKER_ENABLED=false`：保持默认关闭。
- `RAG_RERANKER_ALLOW_MODEL_DOWNLOAD=false`：服务默认只能读取本地缓存。
- 休眠默认候选更新为 `BAAI/bge-reranker-base`、阈值 `0.689045`，并绑定
  `policy-planned-query-v1` 与 `policy-document-type-zh-v1`；该配置不代表模型已获准上线。
- 生产启用前必须扩充近似政策和历史冲突负例，建立与校准集隔离的留出集，再执行授权
  环境的只读数据库与 Provider live 回归。

回滚只需关闭 `RAG_RERANKER_ENABLED`，链恢复 T04 的融合排序与“非空证据”旧门禁；不涉及
数据库迁移或知识库修改。

## 验证命令

```powershell
cd D:\python_play_do\sylg-live\python-rag-service
python -m pytest tests -q
python -m app.evaluation --data ..\server\testdata\ai_eval --k 5 --calibrate-reranker
python -m scripts.compare_rerankers --live --model Xenova/ms-marco-MiniLM-L-12-v2
python -m scripts.compare_rerankers --live --model BAAI/bge-reranker-base

cd D:\python_play_do\sylg-live\server
go test ./internal/ai
go run ./cmd/shenliyuan-ai-eval
```
