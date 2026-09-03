# 校园 Agent A3 事实依据与回答质量门禁

版本：`campus-agent-quality-gate/v1`  
证据类型：`fixture` / `staging` / `online` 分开存档

## 目标与边界

A3 只检查已有校园来源的可核验性，不新增数据源、不改变 Provider，不默认开启
Reranker 或 LangChain 全量路径。评测用例使用 `query_key` 和结论 ID，不保存问题
正文、答案正文、检索正文、Prompt、成绩、课表、账号或凭据。

## 数据分片

唯一清单为：

```text
server/testdata/ai_eval/agent_quality_manifest.json
server/testdata/ai_eval/calibration/cases.jsonl
server/testdata/ai_eval/holdout/cases.jsonl
```

加载器固定知识版本，拒绝以下情况：

- calibration 与 holdout 重复 case ID；
- `related_case_ids` 或 `depends_on` 跨分片引用；
- 分片路径越出清单目录；
- 缺少来源版本、新鲜度、引用定位或拒绝标记；
- 字段名疑似包含问题、答案、凭据或个人数据。

校准集用于固定查询形式（政策别名、口语、错别字、复合问题）和结论契约；留出集
独立覆盖过期来源、来源冲突、可靠拒答、非法引用及历史/现行并存。两者不得合并
计算后再宣称留出集结果。

## 本地门禁

默认只读、无网络、无数据库写入：

```powershell
python scripts/agent_quality_gate.py `
  --manifest server\testdata\ai_eval\agent_quality_manifest.json
```

写入本地报告时，目标必须不存在：

```powershell
python scripts/agent_quality_gate.py `
  --manifest server\testdata\ai_eval\agent_quality_manifest.json `
  --report .\artifacts\a3-quality-fixture.json
```

报告 `blocked=true` 或任一关键门禁为 `fail` 时，知识版本不得发布，灰度不得扩大。
`fixture` 报告只能证明解析器和离线契约；要授权运行时灰度，质量报告必须来自已
授权的 staging 或线上只读采集，并且知识版本与发布清单完全一致。

## 门禁口径

| 门禁 | 通过条件 | 失败动作 |
| --- | --- | --- |
| `citation_validity` | 正常回答的每个引用均指向已发布来源和有效定位；非法引用被可靠拒答 | 阻断发布/扩大灰度 |
| `freshness_safety` | 过期或未知新鲜度来源不被当作确定事实 | 阻断发布/扩大灰度 |
| `key_conclusion_consistency` | 关键结论全部出现且无禁用结论 | 阻断发布/扩大灰度 |
| `refusal_accuracy` | 应拒答用例稳定拒答，正常用例不无故拒答 | 阻断发布/扩大灰度 |
| `historical_boundary` | 历史与现行来源明确分界 | 阻断发布/扩大灰度 |

所有门禁默认阈值为 1.0；阈值只能在评测负责人审查后修改，不能在同一版本的失败
后临时放宽。报告只包含 case ID 和类型化失败码。

## 发布接线

知识库工具的发布命令必须显式传入 A3 报告，且报告为 staging/online 证据：

```powershell
go run ./cmd/shenliyuan-ai-kb dry-run `
  --manifest ..\knowledge-base\sylu-academic-policy\v0.8\release-manifest.v0.8.json `
  --agent-quality-report ..\artifacts\a3-quality-staging.json `
  --require-agent-quality `
  --report ..\artifacts\a3-kb-dry-run.json
```

实际 `release` 还会重新校验报告的 schema、知识版本、所有门禁和零副作用声明；缺失
或失败时在任何写请求前退出。灰度工具通过 `--agent-quality-report` 记录报告摘要，
fixture 不得作为运行时推进凭据。

## 验证命令

```powershell
python -m pytest scripts/test_agent_quality_gate.py -q
cd python-rag-service
python -m pytest tests/test_rollout_guard.py -q
cd ..\server
go test ./cmd/shenliyuan-ai-kb
```
