# 优化基线报告（T00）

> 本模板只接受 `线上`、`staging`、`fixture` 三种证据类型之一。`fixture` 明确表示非生产事实；不得把历史快照或离线结果写成当前线上状态。

## 元数据

- 生成时间（UTC）：
- 执行人：
- 证据类型：
- 分支：
- 提交 SHA：
- 采集模式：`local_read_only_inputs`

## 部署事实

### 二进制/镜像摘要

| 路径 | 大小（字节） | mtime（UTC） | SHA-256 |
| --- | ---: | --- | --- |
|  |  |  |  |

### AI 开关

| 开关 | 代码默认值 | 运行时真值 | 来源/采集时间 |
| --- | --- | --- | --- |
| `AI_POLICY_RAG_ENABLED` |  |  |  |
| `AI_LANGCHAIN_RAG_ENABLED` |  |  |  |
| `AI_LEGACY_RAG_ENABLED` |  |  |  |
| `AI_LANGCHAIN_RAG_ROLLOUT_PERCENT` |  |  |  |
| `AI_AGENT_ENABLED` |  |  |  |
| `RAG_RERANKER_ENABLED` |  |  |  |
| `RAG_RETRIEVER_ENABLED` |  |  |  |
| `RAG_GENERATION_ENABLED` |  |  |  |
| `RAG_SHADOW_INDEX_ENABLED` |  |  |  |
| `RAG_ALLOW_LANGSMITH` |  |  |  |

### 服务、MCP 与知识库

- systemd 服务状态（只读）：
- 外部 MCP：启用状态 / 协议 / 健康状态 / 版本：
- 已发布知识库：版本 / schema / embedding 模型与维度 / 清单摘要：

## 延迟基线（脱敏）

时间点定义：`t_accept`、`t_first_status`、`t_first_delta`、`t_complete`。只保存用例 ID、24 位问题 HMAC 和类型化结果。

HMAC 由上游观测层在内存中使用独立密钥生成；本模板和采集脚本均不接收原问题文本或密钥。

| 用例 ID | 问题 HMAC | `t_accept_ms` | `t_first_status_ms` | `t_first_delta_ms` | `t_complete_ms` | 工具命中 | 取消 | 降级 |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- | --- |
|  |  |  |  |  |  |  |  |  |

派生指标：首字延迟 = `t_first_delta_ms - t_accept_ms`；端到端 = `t_complete_ms - t_accept_ms`。

## 评测基线

- 政策评测集版本 / 冻结 SHA：
- 引用检查口径版本：
- 历史/现行冲突分类版本：
- 应拒答分类版本：

## 缺失项、风险与停止条件

- 缺失项：
- 当前只能证明：
- 尚不能证明：
- 需要的授权/凭据/责任人：
- 回滚或停止条件：

> 禁止记录完整问题、答案正文、检索正文、Prompt、历史消息、个人数据、JWT、Cookie、密码、密钥或数据库 DSN。
