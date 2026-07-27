# T04 LangChain 查询规划与混合召回评测报告

日期：2026-07-27

## 实现口径

- `PolicyQueryPlanner` 是领域规则的唯一生产实现；Go 旧链路只调用受内部 Token 保护的 `/internal/rag/policy/plan`，不再本地解析意图。
- `HybridPolicyRetriever(BaseRetriever)` 同时启动精确、FTS、向量、trigram 四个通道，各通道独立超时；trigram 只在精确与 FTS 候选不足时参与融合。
- 加权 RRF 明细、版本优先级和文档偏好写入 `Document.metadata.score_details`。审计摘要只含内容哈希、分数、版本和 locator。
- 历史文件默认排除；补考/二考/重修相关计划显式允许历史材料，但现行学校文件仍有版本加分。
- 融合后对同文档同章节去重，并优先覆盖不同文档，避免相邻 chunk 占满 Top 6。

## 相对 T01 的指标

| 数据集/模式 | T01 Recall@5 | T04 Recall@5 | 变化 | T01 MRR | T04 MRR | 变化 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 共享 fixture，全部 40 条政策用例 | 100% | 100% | 0 pp | 1.000 | 1.000 | 0.000 |
| 共享 fixture，v0.6 关键 19 条 | 100% | 100% | 0 pp | 1.000 | 1.000 | 0.000 |

T01 的 43 条总报告还包含 3 条引用协议用例；其 Recall@5、MRR、引用合法率和拒答准确率均保持 100%。T04 的 Python 测试直接用共享 JSONL 中的 v0.6 关键 19 条驱动 `HybridPolicyRetriever.invoke`，关键集 Recall@5 与 MRR 均未低于 T01。

本机未配置最小权限 `RAG_DATABASE_DSN`、生产知识库和真实 Provider，因此没有执行 live 新旧对照，不能把 fixture 指标表述为线上指标。live 对照须在授权环境完成角色迁移后运行，并单独保存报告。

## 验证命令

```powershell
cd D:\python_play_do\sylg-live\python-rag-service
python -m pytest tests -q
python -m app.evaluation --data ..\server\testdata\ai_eval --k 5

cd D:\python_play_do\sylg-live\server
go test ./internal/ai
go run ./cmd/shenliyuan-ai-eval
```
