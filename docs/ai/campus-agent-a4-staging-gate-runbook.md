# 校园 Agent A4 staging 故障恢复与回滚门禁

版本：`campus-agent-staging-gate/v1`  
默认模式：`dry_run`，不发请求、不连接 SSH、不修改部署

## 固定输入

每次 staging 验收必须同时记录：

1. 代码版本、知识版本和开关快照；
2. 故障注入分类、恢复结果、用户可见恢复路径和脱敏 Trace 记录；
3. 回滚点、回滚前后版本/开关以及恢复耗时；
4. 请求数、部署变更数和写入声明。

仓库 fixture 位于：

```text
server/testdata/ai_eval/agent_staging/staging_gate.fixture.json
```

它只包含合成版本和状态，不是 staging 事实。

## 故障分类

必须逐项覆盖：`provider_timeout`、`provider_stream_reset`、`retrieval_timeout`、
`tool_timeout`、`tool_error`、`authorization_denied`、`knowledge_stale`、
`network_disconnected`、`context_limit`、`cancelled`、`reconnect`。每项都必须标记
是否注入、是否恢复、是否分类、是否写入 Trace、是否暴露敏感数据，以及用户可见的
恢复路径。任意未恢复、未分类、未记录或暴露敏感数据均阻断。

## 本地 dry-run

```powershell
python scripts/agent_staging_gate.py `
  --fixture server\testdata\ai_eval\agent_staging\staging_gate.fixture.json
```

写本地报告时使用不存在的目标路径：

```powershell
python scripts/agent_staging_gate.py `
  --fixture server\testdata\ai_eval\agent_staging\staging_gate.fixture.json `
  --report .\artifacts\a4-staging-fixture.json
```

通过报告必须满足：版本快照完整、11 类故障全部恢复、Trace 关联率和分类覆盖率为
1、脱敏扫描为 `pass`、回滚点有效且前后状态不同、请求/部署变更/写入均为零。

## 授权 staging 采集

真实 staging 采集器必须先在隔离环境执行故障注入，再把同一契约的脱敏 JSON 交给门禁：

```powershell
python scripts/agent_staging_gate.py `
  --fixture .\artifacts\staging-agent-gate.json `
  --report .\artifacts\staging-agent-gate-checked.json
```

报告的 `evidence_type` 必须为 `staging`，并由发布负责人核对固定代码 SHA、知识版本、
开关快照和观察窗口。fixture 结果不得改标签冒充 staging；未取得授权时只保留
`evidence_type=fixture`。

## 回滚要求

- 回滚点必须在扩大灰度前固定，且 `rollback.before` 必须等于入口快照；
- `rollback.after` 必须明确切回已验证旧代码/知识版本和安全开关；
- 恢复后重复健康、流式、取消、重连、引用和权限负向检查；
- 任一质量、隐私、延迟、错误或权限门禁失败，停止扩大并回滚；
- 记录只包含脱敏状态和时间，不保存问题、答案、个人字段或凭据。

## 验证命令

```powershell
python -m pytest scripts/test_agent_staging_gate.py -q
python -m pytest scripts/test_collect_ai_baseline.py -q
```
