# T08 知识库 v0.6 安全发布与回滚 Runbook

## 安全边界

- 未取得短期管理员 JWT 和发布负责人明确确认时，只允许运行本地 `manifest`、`dry-run` 和测试。
- 工具只通过受认证的管理员 API 写入，不接收数据库 DSN，也不直接连接生产数据库。
- `release`、`rollback` 和单文档动作必须同时提供 `--execute` 与精确确认短语。缺少任一条件时请求数为 0。
- 日志和发布记录不得包含 JWT、服务 Token、数据库地址、完整问题或模型答案。

## 版本契约

v0.6 清单固定以下契约：

| 项目 | 预期值 |
| --- | --- |
| 清单 schema | `sylu-ai-kb-release/v1` |
| 分块器 | `langchain-chinese-policy-v1` |
| embedding 模型 | `sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2` |
| embedding 版本 | `paraphrase-multilingual-minilm-l12-v2-384-v1` |
| 真实维度 | `384` |

任何内容 hash、`document_type`、来源、部门、生效时间、分块器或 embedding 契约漂移都会阻塞发布。历史二考口径必须保留“不得覆盖现行规则”的边界；当前二考口径缺失项继续保留在 `unresolved_items`。

## 生产前准备

1. 由数据库管理员创建时间点备份，并记录备份 ID、恢复命令和校验结果。建议使用平台快照；需要逻辑备份时对生产 DSN 执行受控 `pg_dump --format=custom`，不得把备份提交到仓库。
2. 在只读会话中确认没有重复 published hash：

```sql
SELECT content_hash, COUNT(*), ARRAY_AGG(id ORDER BY id)
FROM ai_knowledge_documents
WHERE deleted_at IS NULL AND status = 'published'
GROUP BY content_hash
HAVING COUNT(*) > 1;
```

3. 检查 `ai_embedding_model_registry` 的活动版本、维度和部署环境 `RAG_EMBEDDING_MODEL_VERSION` 一致。
4. 在维护窗口应用 `server/sql/20260728_ai_knowledge_governance.sql`。如果唯一索引创建失败，停止发布并先人工处理重复项。
5. 确认旧 published 文档的 chunk 和 shadow embedding 仍完整。候选索引失败时不得删除旧文档索引。

## 本地检查

以下命令在 `server` 目录运行，不访问生产 API：

```powershell
go run ./cmd/shenliyuan-ai-kb manifest `
  --output ../knowledge-base/sylu-academic-policy/v0.6/release-manifest.v0.6.json

go run ./cmd/shenliyuan-ai-kb dry-run `
  --report ../artifacts/t08-v06-dry-run.json
```

期望：`manifest_valid=true`、`blocked=false`、`writes_performed=false`。`unresolved_items` 必须包含当前二次考试口径待核验项，不能是固定空数组。

## LangChain 检查

仅连接已授权的内网 Python RAG 服务。该步骤调用 LangChain 分块和 embedding，但不写知识库数据库：

```powershell
$env:RAG_SERVICE_URL = 'http://127.0.0.1:18001'
$env:RAG_SERVICE_TOKEN = '<短期服务令牌>'
go run ./cmd/shenliyuan-ai-kb check
```

期望：14 份候选全部分块，chunk hash 与 locator 有效，模型名、版本和 384 维契约与清单一致。检查过程中不得下载未经批准的新模型。

## 只读生产比对

设置短期管理员 JWT 后执行只读 dry-run：

```powershell
$env:SHENLIYUAN_API_BASE_URL = 'https://<生产管理域名>'
$env:SHENLIYUAN_ADMIN_JWT = '<短期管理员 JWT>'
go run ./cmd/shenliyuan-ai-kb dry-run --check-remote
```

报告必须列出 `add`、`supersede`、`skip` 和 `blocked` 数量。相同 hash 只能 skip；同一政策作用域存在多个 published 版本时必须 blocked。

## 原子发布

发布负责人审核 dry-run、备份 ID 和抽测窗口后，使用清单版本作为确认短语：

```powershell
go run ./cmd/shenliyuan-ai-kb release `
  --execute `
  --confirm 'RELEASE:v0.6' `
  --agent-quality-report '..\artifacts\a3-quality-staging.json' `
  --report '..\artifacts\t08-v06-release-record.json'
```

Agent 知识版本发布还必须提供 `campus-agent-quality-gate/v1` 报告。工具在首个写请求
前校验报告 schema、知识版本、全部 A3 门禁和零副作用声明；`fixture` 证据、过期来源、
非法引用、关键结论冲突或 `blocked=true` 均会阻断发布。该报告不能用来替代 T08 的
清单、备份、远端 hash 和 LangChain 检查。

`--report` 为执行发布的必填项，目标文件必须尚不存在。工具会在首个写请求前独占创建记录文件，在原子发布前写入完整候选 ID，并在发布 API 成功后立即更新；即使后续 smoke-test 失败，也必须保留该文件用于核验和回滚。

工具按 `import -> inspect -> LangChain chunk/embed -> verify -> publish/supersede -> smoke-test` 执行。候选导入和索引阶段不会改变旧 published 状态；最终 publish/supersede 在一个数据库事务中完成。任一候选检查失败时不执行发布事务。

## 发布后验证

1. 发布记录中的变更文档均为 `published`，被替代文档均为 `superseded`。
2. published hash 查询无重复；每个候选的 inspection 中分块器、embedding 版本和维度与清单一致。
3. 检查 chunk 数、空 locator、空章节、异常短块和影子向量数量。
4. 运行共享评测和 19 条 v0.6 回归用例，重点抽测补考、重修、转专业、考试违纪和竞赛奖励。
5. 确认回答把 2004 年 D/F、绩点 1/0 明确标为历史口径，并提示当前执行仍待教务处核验。
6. 观察错误率、拒答率、引用合法率和版本混淆；异常时立即停止流量并回滚。

## 原子回滚

使用发布时生成且权限为仅操作者可读的记录文件：

```powershell
go run ./cmd/shenliyuan-ai-kb rollback `
  --record '..\artifacts\t08-v06-release-record.json' `
  --execute `
  --confirm 'ROLLBACK:v0.6'
```

回滚事务会撤销本批次新增文档，并恢复被本批次 supersede 的旧文档。`unchanged` 的 skip 文档不参与回滚。随后将 RAG 部署配置切回发布前记录的 embedding 模型版本，重启实例并重复 published hash、索引和关键问题抽测。

若管理员 API 不可用，不得自行拼接临时 SQL。由数据库管理员按发布记录和审计日志制定事务脚本，先在恢复环境演练，再经发布负责人确认后执行；必要时使用生产前快照整体恢复。
