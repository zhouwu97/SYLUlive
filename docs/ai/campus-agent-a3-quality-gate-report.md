# 校园 Agent A3 质量门禁交付记录

日期：2026-09-03  
分支：`ai-gongju-shangxiawen`  
证据类型：`fixture`（离线，不代表 staging 或生产）

## 交付内容

- `python-rag-service/app/agent_quality.py`：split manifest 加载、校准/留出互斥校验、
  来源版本/新鲜度/引用/关键结论/拒答/历史边界检查。
- `scripts/agent_quality_gate.py`：机器可读 `campus-agent-quality-gate/v1` 报告和
  非零阻断退出码。
- `server/testdata/ai_eval/agent_quality_manifest.json` 及两个分片：5 条校准用例、
  8 条留出用例，覆盖别名、口语、错别字、关键结论、历史/现行、过期来源、来源冲突、
  可靠拒答和非法引用。
- Go 知识版本 dry-run/release 接线：显式提供 A3 报告时校验 schema、知识版本、门禁
  结果和零副作用；实际 release 要求 staging/online 证据。

## Fixture 结果

运行：

```powershell
python scripts/agent_quality_gate.py `
  --manifest server\testdata\ai_eval\agent_quality_manifest.json
```

结果：校准集 5/5、留出集 8/8；引用合法性、来源新鲜度安全、关键结论一致、应拒答
准确和历史/现行边界均为 `1.0`；`blocked=false`。该结果仅证明代码与脱敏 fixture
契约，不能证明任何 staging 或生产行为。

## 未执行项

尚未取得 staging/生产发布授权，未发送远程请求、未修改部署、未推进灰度。真实环境
需用同一 schema 生成 staging/online 报告，并核对代码版本、知识版本和开关快照后，
再由发布负责人决定是否进入 A4 灰度流程。
