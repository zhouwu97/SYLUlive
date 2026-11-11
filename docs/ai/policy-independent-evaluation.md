# 真实政策评测

离线契约测试使用 Fake 模型，负责协议、权限、引用和异常分支；真实质量由显式开启的实测工具验证。两种结果分开报告，不能把 Fake 回答或原有夹具的 100% 当成真实模型正确率。

## 数据与隔离

校准问题是 `server/testdata/ai_eval/policy_quality.jsonl` 中的 42 题。独立问题维护在 `server/testdata/ai_eval/policy_holdout/manifest.json`，首次调用真实模型前冻结；工具检查规范化后不与校准问题重复、ID 唯一，并拒绝把固定 `answer` 或 `fixture` 放入留出集。

评测完整读取知识库正式导入 JSONL，复用生产 `chunk_policy_document`、`PolicyQueryPlanner`、`PolicyReranker` 与 `build_policy_rag_chain`。本机召回使用按规划域约束的 BM25，明确标记为本机完整语料检索，不代表生产 PostgreSQL FTS/向量/RRF 的全栈验收。校准和留出测试必须使用相同的语料哈希、召回版本、真实权重版本与资源配置；工具拒绝错配报告。

阈值仅从校准问题确定，不从留出题目调整。留出题暴露缺陷并用于修复后的回归后，不再把同一批题的后续运行描述成全新盲测。保存首次失败和后续结果，不删除失败项，不以修改题目或答案事实掩盖错误。小样本结果不能外推为生产所有问题的正确率。

## 本机操作

使用已安装 `python-rag-service/requirements.txt` 的隔离环境。真实权重必须由维护者事先下载到缓存目录；评测运行本身禁止自动下载，未使用真实权重或发生 rerank 降级时不能作为有效通过。

```powershell
$env:PYTHONPATH = "$PWD/python-rag-service"
python -m scripts.evaluate_policy_holdout --live --calibrate-only `
  --calibration-data server/testdata/ai_eval `
  --calibration-report _codex_evidence/live-calibration.json `
  --holdout server/testdata/ai_eval/policy_holdout/manifest.json `
  --corpus "knowledge-base/sylu-academic-policy/v0.6/SYLUlive_AI官方全文导入包_v0.6.jsonl" `
  --reranker-cache C:/private/reranker-cache --reranker-threads 4 `
  --output _codex_evidence/live-calibration.json

python -m scripts.evaluate_policy_holdout --live `
  --calibration-data server/testdata/ai_eval `
  --calibration-report _codex_evidence/live-calibration.json `
  --holdout server/testdata/ai_eval/policy_holdout/manifest.json `
  --corpus "knowledge-base/sylu-academic-policy/v0.6/SYLUlive_AI官方全文导入包_v0.6.jsonl" `
  --reranker-cache C:/private/reranker-cache --reranker-threads 4 `
  --astrbot-config C:/private/AstrBot/data/cmd_config.json `
  --model-id mimo-v2.6-flash --allow-provider-origin https://api.xiaomimimo.com/v1 `
  --output _codex_evidence/live-holdout.json
```

配置只在内存读取，Provider origin 必须与显式白名单一致，报告不写密钥或私有配置内容。该入口借用维护者已配置的生成模型，不改变生产 Provider、生产模型锁或开关。CPU 评测使用批量 2、最多 512 字符的重排输入、20 个候选和 10 个重排结果，正文与引用仍保留完整分块；必须在报告中标明资源配置，不当作生产吞吐承诺。

报告记录题目 ID、状态、事实/引用/来源检查结果、真实 token 用量和耗时；中途结果标记 `incomplete`，不得当作最终报告。`--case-id` 仅用于定位单题，不能冒充全量。默认不保存答案和提示词；确需定位公开政策生成错误时可用 `--public-audit` 在本机保留公开答案、引用与证据，密钥被剔除，严禁把学校个人资料混入这一入口。任何真实学号、成绩、密码或会话都不得进入模型评测语料。

## 判断通过

有答案的问题同时检查有效来源、实际事实、引用编号、来源文档/分块对和无重排降级；无法核验、个人成绩、代开正式材料、外部实时数据和提示注入问题检查回答边界。失败返回非零退出码。真实调用用量必须非零，不能回放固定答案冒充真实生成。发布仍需生产只读检索、服务版本、配额/撤权、灰度和回滚验证，入口见现有 RAG 运维文档。
