# 沈理校园 Agent A0 基线交付记录

日期：2026-09-03  
分支：`ai-gongju-shangxiawen`  
证据类型：`fixture`（离线契约证据，不代表 staging 或生产）  
仓库基线提交：`b866ceac71e04c86922af132f11848fd239e0bcc`（当前工作树含未提交计划改动）

## 采集命令

```powershell
python scripts/collect_ai_baseline.py `
  --evidence-type fixture `
  --repo . `
  --scenario-manifest server/testdata/ai_eval/campus_agent_scenarios.json `
  --events-jsonl server/testdata/ai_eval/campus_agent_events.fixture.jsonl `
  --markdown-output <临时路径> `
  --execute --confirm WRITE:T00-BASELINE
```

## Fixture 结果

| 项目 | 结果 |
| --- | ---: |
| 场景覆盖 | 8 / 8 |
| 事件数 | 41 |
| 首个 answer.delta 场景数 | 8 / 8 |
| 重连场景数 | 1 |
| Grant 失败次数 | 0 |
| 最大可见工具数 | 4 |
| 最大 Schema token 估算 | 322 |
| Provider / RAG / 工具耗时总和（ms） | 152 / 120 / 102 |

事件契约为 `t00-baseline-events/v1`，场景清单为
`campus-agent-scenarios/v1`，覆盖政策通知、校历、食堂、公开竞赛、已授权学业、
课表、个人日历和失败恢复八类场景。事件中只保留用例 ID、24 位 HMAC 和类型化指标，
未保存问题、答案、个人字段或凭据。

## 未完成的事实采集

本地 fixture 不包含部署二进制摘要、运行时开关真值、外部 MCP 状态、已发布知识库版本、
systemd 状态或四时间点延迟记录。因此 A0 当前只能证明采集器、事件契约、场景清单和
脱敏规则可复跑，不能形成 staging/生产基线，也不能据此宣称线上优化收益。

待取得隔离 staging 或生产只读授权后，必须使用同一采集器分别生成 `staging` 或
`online` 报告，并独立核对代码版本、知识版本、开关快照和测试账号；不得把本 fixture
改标签为更强证据。

## 结论

- A0 的离线输入契约和可复跑 fixture 验收完成。
- 真实环境版本、配置、资源和延迟事实仍是发布前阻塞项。
- 在这些事实补齐前，不进入线上性能或质量收益结论。
