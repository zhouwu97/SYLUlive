# T00 优化基线与验收口径（脱敏基线采集说明 + 报告模板）

日期：2026-09-02
分支：`ai-gongju-shangxiawen`
性质：第 0 步正式交付物。仅新增基线采集说明、报告模板与验收口径，**不改变 Provider、RAG、数据库或公网配置**。

> 目的：为后续“更快、更准”的判断建立统一基准，明确区分三种状态——**代码已具备的能力 / 已发布到生产的能力 / 尚待验证的优化假设**。

---

## 1. 范围与边界

- **只读**：本步骤只采集与记录，不修改任何运行配置。
- **不处置项**：`*:8080` 全网卡监听收紧归第 10 步；Reranker、LangChain RAG 全量开关等灰度与回滚归第 3/4 步。
- **脱敏硬约束**：日志、报告、提交信息中不得出现完整问题、答案正文、检索正文、Prompt、JWT、Cookie、密码、密钥或数据库 DSN。

## 2. 只读采集对象

| # | 采集对象 | 记录内容 | 方法 |
| --- | --- | --- | --- |
| 1 | 部署二进制/镜像摘要 | 路径、大小、mtime、sha256 | `sha256sum` / `stat`（只读） |
| 2 | AI 开关运行时真值 | 见下开关表 | 读 `.env`（root 0600，需 sudo 授权） |
| 3 | 外部 MCP 状态 | 是否启用、协议（stdio）、健康状态 | 只读进程/配置查看 |
| 4 | 已发布知识库版本 | 版本号、清单 schema、embedding 版本/维度 | 管理员 API 只读 / DB 只读 |
| 5 | systemd 服务状态 | active/failed、最近启动时间、pid | `systemctl status`（只读） |

### 2.1 开关真值采集表（代码默认值 vs 生产真值）

| 开关 | 代码默认值 | 生产真值（待填） |
| --- | --- | --- |
| `AI_POLICY_RAG_ENABLED` | `false` | ＿ |
| `AI_LANGCHAIN_RAG_ENABLED` | `false` | ＿ |
| `AI_LEGACY_RAG_ENABLED` | `true` | ＿ |
| `AI_LANGCHAIN_RAG_ROLLOUT_PERCENT` | `0` | ＿ |
| `AI_AGENT_ENABLED` | `false` | ＿ |
| `RAG_RERANKER_ENABLED` | `false` | ＿ |
| `RAG_RETRIEVER_ENABLED` | `true` | ＿ |
| `RAG_GENERATION_ENABLED` | `true` | ＿ |
| `RAG_SHADOW_INDEX_ENABLED` | `true` | ＿ |
| `RAG_ALLOW_LANGSMITH` | `false` | ＿ |

## 3. 延迟四时间点采集规范（脱敏）

### 3.1 时间点定义

| 标识 | 含义 | 采集方式 |
| --- | --- | --- |
| `t_accept` | 请求接受 | 服务端接收请求的日志时间戳 |
| `t_first_status` | 首个状态 | 首个状态事件的广播时间 |
| `t_first_delta` | 首个文本增量 | 首个 `answer.delta` 广播时间 |
| `t_complete` | 完整回答 | 完成事件时间 |

派生指标：首字延迟 = `t_first_delta - t_accept`；端到端 = `t_complete - t_accept`。

### 3.2 脱敏与存储规则

- 使用**隔离测试账号** + **固定公开用例**采集，不使用真实学生账号。
- 只保存三类信息：**用例 ID**、**问题文本的 24 位 HMAC 摘要**、**类型化结果**（各时间点毫秒差、是否命中工具、是否取消）。
- HMAC 摘要统一使用独立密钥 `RAG_OBSERVABILITY_HASH_SECRET` 或等价独立密钥生成，密钥不落盘、不进报告。
- 禁止保存：完整问题、答案正文、历史消息、检索正文、Prompt、JWT、密钥、DSN。

### 3.3 采集脚本输出契约

采集脚本只输出类型化 JSONL，字段固定如下：

```json
{"case_id":"c001","q_hmac":"<24位HMAC>","t_accept_ms":12,"t_first_status_ms":80,"t_first_delta_ms":720,"t_complete_ms":3100,"tool_hit":false,"cancelled":false,"degraded":null}
```

`collect_ai_baseline.py` 不接收原问题文本，也不持有 HMAC 密钥。上游服务或
测试夹具应在内存中使用独立密钥生成 `q_hmac`，只把摘要写入 JSONL；本工具
仅校验摘要格式、时间点和字段脱敏契约。

## 4. 基线报告模板

```markdown
# 优化基线报告（可复跑）

- 日期 / 执行人 / 分支与提交 SHA：
- 证据类型：[线上 | staging | fixture]（三选一，明确标注）

## 部署事实
- 主二进制 sha256：＿＿
- AI 开关真值：＿＿（附开关表）
- 外部 MCP 状态：＿＿
- 已发布知识库版本：＿＿

## 延迟基线（脱敏）
| 用例 ID | t_first_delta | t_complete | 工具命中 | 取消 | 降级 |
| --- | --- | --- | --- | --- | --- |
| c001 | ＿ | ＿ | ＿ | ＿ | ＿ |

## 评测基线（冻结）
- 政策评测集版本 / 冻结 SHA：＿＿
- 引用检查口径 / 故障分类版本：＿＿

## 结论与阻塞项
- ＿
```

## 5. 验收口径：三类证据标注

| 证据类型 | 定义 | 标注要求 |
| --- | --- | --- |
| `线上` | 生产环境采集 | 标注采集时间、脱敏摘要、是否受灰度影响 |
| `staging` | 预发环境采集 | 标注 staging 版本 SHA 与配置摘要 |
| `fixture` | 离线/测试夹具 | 明确“非生产事实”，禁止据此宣称线上结论 |

- **评测版本冻结**：政策评测集版本与冻结 SHA 必须在报告中标明，复跑必须可回溯到同一版本。
- **故障分类冻结**：引用检查、历史/现行冲突、应拒答等故障分类口径在基线中固定，后续步骤沿用。

## 6. 验收 / 停止条件

1. 形成**可复跑基线报告**，四时间点、开关真值、评测冻结版本齐备。
2. 三类证据（线上/staging/fixture）标注清晰，无相互混淆。
3. 若生产二进制摘要显示**不含真流式代码**，第 1 步仅发布该已有能力，不混入模型替换或 RAG 改造。

## 7. 与后续步骤的关系

- 第 1 步依赖本步骤的二进制摘要与流式能力判断；
- 第 3/4 步依赖本步骤冻结的政策评测版本；
- 第 6 步依赖本步骤的脱敏指标口径与 HMAC 摘要约定。

## 8. 本地采集工具（默认 dry-run）

仓库提供 `scripts/collect_ai_baseline.py`，只读取显式指定的本地文件和
`systemctl show` 只读结果，不负责 SSH、HTTP、数据库写入或生产配置变更。
工具只解析开关白名单、MCP/知识库元数据白名单和固定字段 JSONL，不会把
环境文件中的未知变量复制到报告。

预览采集计划（不写文件）：

```powershell
python scripts/collect_ai_baseline.py `
  --evidence-type fixture `
  --repo .
```

写出报告必须显式提供确认短语；报告建议放在被忽略的 `artifacts/` 目录，
并在提交前检查其中没有完整问题、答案或凭据：

```powershell
python scripts/collect_ai_baseline.py `
  --evidence-type fixture `
  --repo . `
  --runtime-env .env `
  --defaults-env .env.example `
  --timings-jsonl .\artifacts\t00-timings.jsonl `
  --output .\artifacts\t00-baseline.json `
  --markdown-output .\artifacts\t00-baseline.md `
  --execute --confirm WRITE:T00-BASELINE
```

`online` 证据另需 `WRITE:T00-ONLINE-READONLY` 确认，但该工具仍不会代替
生产授权、SSH 登录或隔离测试账号；缺少授权时只能保留 `fixture`/`staging`
标记并记录未采集项。独立模板见
`docs/ai/t00-baseline-report-template.md`，测试命令为：

```powershell
python -m pytest scripts/test_collect_ai_baseline.py -q
```

## 9. 校园 Agent 事件与场景清单

基线采集必须同时绑定一个固定场景清单和一份事件 JSONL。场景清单只包含
脱敏的 `case_id`、能力范围和类型化预期，不包含问题、答案、Grant、subject、
账号或个人字段；事件 JSONL 只允许保存 24 位问题 HMAC、事件顺序、耗时、工具
计数、授权失败计数、知识版本和降级类型。采集器会拒绝缺少场景、事件越序、
工具调用未闭合或终态缺失的输入。

使用仓库 fixture 做离线契约检查（不会连接任何服务，也不会产生 staging/线上
事实）：

```powershell
python scripts/collect_ai_baseline.py `
  --evidence-type fixture `
  --repo . `
  --scenario-manifest .\server\testdata\ai_eval\campus_agent_scenarios.json `
  --events-jsonl .\server\testdata\ai_eval\campus_agent_events.fixture.jsonl
```

在授权的 staging 采集时，先把隔离环境生成的脱敏事件文件和场景清单显式传入，
并把输出标记为 `staging`；不得用 fixture 事件冒充 staging 运行结果：

```powershell
python scripts/collect_ai_baseline.py `
  --evidence-type staging `
  --repo . `
  --scenario-manifest .\artifacts\staging-campus-scenarios.json `
  --events-jsonl .\artifacts\staging-campus-events.jsonl `
  --output .\artifacts\staging-t00-baseline.json `
  --markdown-output .\artifacts\staging-t00-baseline.md `
  --execute --confirm WRITE:T00-BASELINE
```

`online` 仅表示生产环境只读采集，必须由发布负责人另行授权并使用隔离测试账号；
它不能复用 `fixture` 或 `staging` 的输出路径和证据标签：

```powershell
python scripts/collect_ai_baseline.py `
  --evidence-type online `
  --repo . `
  --scenario-manifest .\artifacts\online-campus-scenarios.json `
  --events-jsonl .\artifacts\online-campus-events.jsonl `
  --output .\artifacts\online-t00-baseline.json `
  --markdown-output .\artifacts\online-t00-baseline.md `
  --execute --confirm WRITE:T00-ONLINE-READONLY
```

报告中的 `evidence_type` 必须与实际运行环境一致。fixture 结果只能证明代码、
解析器和脱敏契约；staging 结果只能证明对应 staging 版本和开关快照；线上结果
还必须附部署版本、配置真值、采集时间和灰度影响。三类证据分别存档，不能合并
样本、拼接指标或用较弱证据替代较强证据。缺少 staging/生产授权时，停止在
fixture 证据，不写“线上已优化”或“生产已通过”。
