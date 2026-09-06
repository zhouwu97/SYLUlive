# T09 LangChain RAG 观测、灰度与回滚 Runbook

## 发布不变量

- 没有生产 JWT、管理员 JWT 和变更授权时，只能运行本地测试及工具 dry-run，不得请求生产接口。
- LangSmith 默认关闭。日志、指标、Trace 和报告不得包含完整问题、历史、检索正文、Prompt、答案、JWT、密钥或数据库 DSN。
- 灰度只能按 `off -> internal -> 5 -> 20 -> 50 -> 100` 推进。禁止直接修改生产全量开关绕过门禁状态与证据。
- 100% 阶段仍保持 `AI_LEGACY_RAG_ENABLED=true`，完成观察窗口和单独评审前不得移除旧 Go 路径。
- 影子索引先构建、比对、观察，再切换读取；禁止原地覆盖当前已发布索引。
- 本 Runbook 不包含 MCP、Agent、Tool Calling 或 LangGraph，它们不是本次发布前置条件。

## 配置与职责

| 配置 | 默认值 | 作用与回滚语义 |
| --- | --- | --- |
| `AI_LANGCHAIN_RAG_ENABLED` | `false` | Go 侧 LangChain 总开关 |
| `AI_LANGCHAIN_RAG_ROLLOUT_PERCENT` | `0` | 稳定账号分桶比例，只能由顺序灰度门禁推进 |
| `AI_LEGACY_RAG_ENABLED` | `true` | 旧 Go 路径；灰度和 100% 观察窗口均保留 |
| `RAG_RETRIEVER_ENABLED` | `true` | Python 召回开关；关闭后稳定返回 503 |
| `RAG_RERANKER_ENABLED` | `false` | 重排开关；关闭后恢复无重排链路 |
| `RAG_GENERATION_ENABLED` | `true` | Python 生成开关；关闭后稳定返回 503 |
| `RAG_SHADOW_INDEX_ENABLED` | `true` | 向量影子索引读取开关；关闭后只使用非向量通道并记录降级 |
| `RAG_ALLOW_LANGSMITH` | `false` | 外发追踪前置门禁，本次发布必须为 `false` |
| `RAG_OBSERVABILITY_HASH_SECRET` | 无 | 独立 HMAC 密钥，生产必须由密钥系统注入 |

开关在进程启动时读取，变更后必须滚动重启并重新检查 `/health`。Go 保留认证、额度、预算、SSE、来源二次校验和结算；Python 只负责版本化 LCEL RAG 编排。

## 部署前检查

1. 固化待发布 Go 二进制、Python 镜像、配置和当前数据库备份标识，记录可回滚的上一版本摘要。
2. 执行 T08 Runbook 的只读 readiness、published hash、清单、冲突和影子索引比对。候选索引失败时停止发布，旧索引保持不变。
3. Python 数据库账号只能继承 `shenliyuan_rag_reader`，并设置 `default_transaction_read_only=on`。不得把 Go 写账号或管理员账号注入 Python。
4. 在数据库侧核对三张检索表只有 `SELECT`，没有 `INSERT/UPDATE/DELETE/TRUNCATE`；再检查 `/health.dependencies_ready.policy_database=true`。
5. 确认 `RAG_ALLOW_LANGSMITH=false`、两个追踪变量为 `false`，`/internal/rag/metrics.export.mode=local_only`。
6. 运行本仓库全量验收命令和 T01 评测。v0.6 关键 19 条 Recall@5 必须为 100%，扩展集 Recall@5 不低于 90%，引用合法率 100%，关键结论一致率不低于 95%，历史/现行混淆为 0。
7. 在隔离环境完成安全回归、并发预算、慢客户端和取消测试。缺少外部依赖的项目必须标记 `not_run`，不能写成通过。

只读角色创建示例：

```sql
CREATE ROLE shenliyuan_rag_runtime LOGIN PASSWORD '<由密钥系统生成>'
    IN ROLE shenliyuan_rag_reader;
ALTER ROLE shenliyuan_rag_runtime SET default_transaction_read_only = on;
```

## 扩缩容与模型缓存

- 单个 Python 进程使用一个 Uvicorn worker，避免同一容器重复加载 embedding/reranker。通过增加容器副本横向扩容，先扩容再提高灰度比例。
- `RAG_MAX_CONCURRENCY` 上限为 4。根据模型内存、数据库连接数和 Provider 并发预算逐级提高，禁止把压测并发直接照搬到生产。
- `/models/fastembed` 使用持久卷 `rag_model_cache`。发布前在隔离构建阶段预热已批准的精确模型版本，生产设置 `RAG_RERANKER_ALLOW_MODEL_DOWNLOAD=false`。
- 每个副本的指标为进程内有界窗口；采集器按副本拉取并聚合。所有副本必须使用同一专用 HMAC 密钥，但密钥本身不得进入指标。
- 缩容前先从负载均衡摘除副本并等待进行中请求结束。取消或超时必须传播到 Python、reranker 和 Provider。

## 本地观测

使用内部服务 Token 拉取：

```powershell
Invoke-RestMethod `
  -Uri 'http://127.0.0.1:18001/internal/rag/metrics' `
  -Headers @{ 'X-Internal-Service-Token' = $env:RAG_SERVICE_TOKEN }
```

门禁证据至少包含 `chain_name=shenliyuan_policy_rag`、`chain_version=observability-release-v5`、请求状态、计划类型、候选数、exact/FTS/vector/trigram 耗时与结果、retrieval/rerank/generation/引用校验/端到端 p50/p95/p99、门禁结果、usage、降级模式。查询只允许记录 24 位 HMAC 摘要。

## 端到端与压测

所有工具默认 dry-run，不发送请求：

```powershell
.\scripts\verify_ai_t09.ps1

cd python-rag-service
python scripts/load_test_policy_rag.py --requests 20 --concurrency 4
python scripts/rollout_guard.py --state .\artifacts\t09-rollout.json --target internal
```

端到端演练必须使用隔离的高额度测试账号，执行前至少剩余 6 个可预留 Run。普通生产账号的默认额度不能为了演练而提高。取消场景应使用带可控延迟 Provider 的隔离部署；若回答先完成，脚本明确失败，不能把竞态写成通过。

```powershell
.\scripts\verify_ai_t09.ps1 `
  -BaseUrl 'https://staging.example.invalid' `
  -Jwt $env:T09_TEST_JWT `
  -AdminJwt $env:T09_ADMIN_JWT `
  -ExpectedRagPath langchain `
  -RevokedChunkId 123 `
  -Execute -Confirm 'RUN:T09-E2E'
```

额度耗尽会实际消费测试账号剩余额度，还必须显式提供 `-RunQuotaExhaustion -ConfirmQuotaExhaustion 'CONSUME:REMAINING-QUOTA'`。脚本不撤销知识，只验证预先撤销的 `RevokedChunkId` 返回 404。

压测只允许指向隔离环境。远程目标需要 `--allow-remote`，确认短语必须精确匹配请求数和并发数，报告文件必须不存在：

```powershell
cd python-rag-service
python scripts/load_test_policy_rag.py `
  --base-url 'https://staging-rag.example.invalid' `
  --token $env:RAG_SERVICE_TOKEN `
  --requests 100 --concurrency 8 `
  --report .\artifacts\t09-load-c8.json `
  --allow-remote --execute --confirm 'LOAD:100:8'
```

报告只保存固定用例编号，记录查询规划、召回、rerank、首字、完整回答和端到端 p50/p95/p99，以及吞吐、错误率和错误类别。阶段负责人必须在 `pass` 前写入已批准的延迟、错误率与成本阈值；阈值不得在同一灰度阶段中途放宽。

## 安全回归矩阵

| 风险 | 自动化证据 |
| --- | --- |
| 提示词注入、恶意知识指令 | `test_t09_observability_security.py` 与链引用校验测试 |
| Provider Base URL 注入 | 严格请求 Schema 与 Provider 白名单测试 |
| 超大 payload | Pydantic 长度/额外字段拒绝测试 |
| 慢客户端、断线恢复、取消 | T09 端到端脚本及 Go/Python 取消传播测试 |
| 重复请求、额度、并发预算 | Go Runtime/Handler 幂等、额度和结算测试 |
| 数据库只读权限 | `PostgresPolicySearchStore.check_read_only_permissions` 契约测试与部署前实库检查 |
| 敏感内容进入指标 | 本地 Callback 脱敏测试与指标 JSON 抽检 |
| 未审查 LangSmith 外发 | 默认强制关闭测试与部署配置核对 |

## 顺序灰度

每阶段生成脱敏证据 JSON，八个门禁必须全部为 `pass`：`quality`、`error_rate`、`latency`、`cost`、`observability`、`security_regression`、`rollback_drills`、`shadow_index_comparison`。`internal` 之前证据阶段写 `preflight`；后续证据的 `stage` 必须等于当前阶段，且观测样本数大于 0。

```json
{
  "schema_version": "t09-rollout-evidence/v1",
  "stage": "preflight",
  "sample_size": 0,
  "gates": {
    "quality": "pass",
    "error_rate": "pass",
    "latency": "pass",
    "cost": "pass",
    "observability": "pass",
    "security_regression": "pass",
    "rollback_drills": "pass",
    "shadow_index_comparison": "pass"
  }
}
```

推进命令默认只预览。写状态必须同时提供证据、`--advance` 和精确确认短语：

```powershell
python scripts/rollout_guard.py `
  --state .\artifacts\t09-rollout.json `
  --target internal `
  --evidence .\artifacts\preflight-evidence.json `
  --agent-quality-report .\artifacts\a3-quality-staging.json `
  --require-agent-quality `
  --advance --confirm 'ADVANCE:internal'
```

状态文件只生成下一阶段环境建议和证据 SHA-256，不直接修改部署。变更负责人核对输出后才能通过受审计的部署系统应用配置。每阶段至少观察一个预先批准的完整窗口，检查质量、错误率、成本、延迟、拒答、引用合法性和降级模式，再按 `internal -> 5 -> 20 -> 50 -> 100` 重复。任何门禁失败立即停止推进并回滚，禁止跳阶段补写状态。

对于本计划的校园 Agent，`--agent-quality-report` 是 A3 的独立前置门禁：报告必须为
`campus-agent-quality-gate/v1`，知识版本与待推进版本一致，所有引用/新鲜度/关键结论/
拒答/历史边界门禁通过，且 `evidence_type` 为已授权的 `staging` 或 `online`。fixture
报告只能做离线检查，不能授权运行时灰度；质量报告摘要和 SHA-256 会写入本地灰度历史。

## 回滚与演练

灰度回滚命令仍需当前阶段证据，且只把本地门禁状态回到 `off`：

紧急回滚只校验证据的 Schema、阶段和八个门禁结果是否完整，不要求门禁为 `pass`；故障门禁应如实记录为 `fail`。该证据可以回滚，但绝不能用于继续推进灰度。

```powershell
python scripts/rollout_guard.py `
  --state .\artifacts\t09-rollout.json `
  --target rollback `
  --evidence .\artifacts\current-stage-evidence.json `
  --advance --confirm ROLLBACK
```

部署回滚按以下顺序执行：

1. 将 `AI_LANGCHAIN_RAG_ENABLED=false`、比例设为 `0`，确认 `AI_LEGACY_RAG_ENABLED=true`，滚动重启 Go；从 `run.created.rag_path=legacy_go` 证明旧路径已接管。
2. LangChain 服务关闭演练：在隔离环境停止 Python 副本，验证未命中 LangChain 的账号继续走旧路径；已命中账号必须确定性失败且不双重计费。随后恢复副本并检查健康。
3. 知识撤销演练：按 T08 工具撤销专用测试文档，确认旧来源展开为 404、回答不再引用；再按 T08 原子回滚恢复。禁止直接改生产表。
4. 旧索引恢复演练：关闭 `RAG_SHADOW_INDEX_ENABLED` 或把读取版本切回已记录的旧索引，核对模型/维度匹配、关键问题和引用合法性；影子索引保留用于事后分析。
5. 二进制回滚：从负载均衡摘除实例，恢复上一 Go 二进制和 Python 镜像摘要，保留向前兼容的数据库迁移与影子索引，滚动启动并重复健康、契约、关键问题和来源展开检查。不得在线删表或覆盖索引。

演练记录必须包含时间、环境、发布版本、执行人、命令、脱敏证据摘要、恢复时间和结论。生产未授权或缺少测试文档时，结论只能写“待授权/未执行”。
