# 校园 Agent A4 staging 门禁交付记录

日期：2026-09-03  
分支：`ai-gongju-shangxiawen`  
证据类型：`fixture`（离线，不代表 staging 或生产）

## 交付内容

- `python-rag-service/app/agent_staging_gate.py`：固定版本/开关快照、故障分类覆盖、
  脱敏观测、回滚前后状态及零副作用校验。
- `scripts/agent_staging_gate.py`：默认 dry-run 的机器可读门禁 CLI。
- `server/testdata/ai_eval/agent_staging/staging_gate.fixture.json`：覆盖 11 类故障、
  恢复路径和固定回滚点的合成 fixture。
- Go Runtime 的 `run.failed` 和 `run.cancelled` 事件现在写入稳定的
  `failure_class` 与 `recovery_path`；Trace 指标以 `failure_classes` 独立聚合，旧的
  `failure_reason` 字段保持兼容。

## Fixture 结果

运行：

```powershell
python scripts/agent_staging_gate.py `
  --fixture server\testdata\ai_eval\agent_staging\staging_gate.fixture.json
```

结果：版本快照、故障注入、观测、回滚和副作用 5 个门禁均为 `pass`；请求数和部署
变更数为 0；`decision=pass`。这只证明门禁代码和 fixture，不是 staging/生产验收。

## 未执行项

尚未取得真实 staging 或生产授权，未执行网络故障注入、服务重启、灰度推进或回滚。
后续必须在隔离 staging 生成 `evidence_type=staging` 记录，核对固定版本与观察窗口，
再由发布负责人决定是否推进；任何失败都应停在当前阶段并使用已验证回滚点。
