# 政策 RAG 与校园 Agent 共享评测数据

本目录是 Go 评测 Runner 与后续 Python LangChain 测试的唯一政策 RAG 数据源。每个
政策 `.jsonl` 文件一行一个用例，并共同遵循 `schema.json`；禁止在 Python 侧复制或改写
字段语义。

## 政策 RAG 文件

- `citation_validation.jsonl`：保留既有引用白名单与格式用例。
- `policy_quality.jsonl`：政策检索、生成、拒答和安全用例。
- `schema.json`：版本化输入契约，当前为 v1。

## 运行模式

- `fixture`：默认模式，只读取用例内的 `fixture`，不读取环境变量，不连接数据库、
  RAG 服务或模型 Provider。该模式用于验证评测数据、Runner 和固定输出，可复现但不
  代表线上服务的实时质量。
- `live`：必须显式传入 `--mode live`，并提供 CLI 报错中列出的数据库、RAG 服务和
  Provider 配置。该模式复用生产接口做只读评测，缺少依赖时必须非零退出。

失败报告只写公开用例 ID 和类型化原因，不写完整问题、模型回答、密钥或连接串。

## 校园 Agent A0 输入

- `campus_agent_scenarios.json`：八类校园场景的能力和预期类型化结果；不保存问题、答案、
  Grant、subject、账号或个人字段。
- `campus_agent_events.fixture.jsonl`：事件契约的最小示例，只证明解析格式，不代表完整场景
  运行，更不代表 staging 或生产结果。

运行时采集必须用同一 `case_id` 覆盖 `campus_agent_scenarios.json` 中的所有场景；每条
事件仅可保存 24 位问题 HMAC、事件顺序、耗时、工具数量、授权失败计数、知识版本和
降级类型。真实学生提问、成绩、课表、令牌和完整回答不得写入此目录或基线报告。

## 校园 Agent A3 校准集与留出集

- `agent_quality_manifest.json`：固定 `calibration`/`holdout` 路径、case ID、知识版本和质量门槛。
- `calibration/cases.jsonl`：用于校准查询规划和回答约束的脱敏结构化用例。
- `holdout/cases.jsonl`：与校准集互斥的独立留出用例，用于发布前质量门禁。

A3 用例只保存 `query_key`、输入形式、来源 ID/版本/新鲜度、引用定位、结论 ID 和
`refused` 布尔值，不保存 `question`、`answer`、正文、Prompt、个人字段或凭据。加载器
会拒绝重复 case ID、calibration/holdout 交叉引用、越界分片路径和敏感字段。

运行独立门禁（默认只读、无网络请求）：

```powershell
python scripts/agent_quality_gate.py `
  --manifest server\testdata\ai_eval\agent_quality_manifest.json
```

输出的 `campus-agent-quality-gate/v1` 报告同时给出校准集和留出集的引用合法性、来源
新鲜度安全、关键结论一致、应拒答准确和历史/现行边界指标。任一指标低于门槛时，
`blocked=true`，`publish_decision` 与 `rollout_decision` 均为 `blocked`，调用方不得发布
该知识版本或扩大灰度。fixture 报告仅证明代码和契约，不是 staging/生产证据。
