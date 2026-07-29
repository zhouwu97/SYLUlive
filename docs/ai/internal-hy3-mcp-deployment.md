# 内置 AI 接入独立 Hy3 MCP

本文描述 SYLUlive 服务端通过受控 `stdio` 调用独立 Hy3 MCP 的部署方式。

链路固定为：

```text
Flutter -> HTTPS Go AI Runtime -> Go 决策包装工具 -> MCP stdio -> SYLUlive_MCP -> Hy3 API
```

Flutter 不保存 MCP 地址、SSH 私钥或 Hy3 API Key。Go 服务不保存 Hy3 API Key，也不会向公网监听 MCP HTTP 端口。

## 前置条件

独立 MCP 项目部署在与主服务隔离的目录和运行账户下，例如：

```text
/opt/SYLUlive_MCP
/opt/SYLUlive_MCP/bin/run-stdio
```

MCP 的运行环境文件由 MCP 服务器本机持有，权限应为仅执行 `run-stdio` 的账户可读：

```dotenv
HY3_MODE=live
HY3_API_BASE=https://tokenhub.tencentmaas.com/v1
HY3_API_KEY=在此处配置并定期轮换
HY3_MODEL=hy3-preview
```

不要将该文件放入 Go 服务目录、Flutter 工程、Git 仓库或 CI 日志。在 `local_stdio` 下，子进程继承 Go 服务账户，因此该账户也能读取此文件；若该信任边界不可接受，必须改用下面的受限 SSH 账户方案。

## 同机部署

当 Go AI Runtime 与 MCP 位于同一台服务器、且允许它们共享同一 Unix 信任边界时，可使用本机子进程，不需要 SSH 或额外端口。Go 必须启动固定包装器，由包装器加载 MCP 自己的环境文件；不要直接指向 Python CLI：

```dotenv
AI_EXTERNAL_MCP_ENABLED=true
AI_EXTERNAL_MCP_TRANSPORT=local_stdio
AI_EXTERNAL_MCP_COMMAND=/opt/SYLUlive_MCP/bin/run-stdio
AI_EXTERNAL_MCP_TOOL_TIMEOUT_SECONDS=90
AI_EXTERNAL_MCP_MAX_CALLS_PER_RUN=1
```

`AI_EXTERNAL_MCP_COMMAND` 必须是单个可执行文件的绝对路径。程序不会解释 Shell 字符串，因此不能填入参数拼接、管道或重定向。`run-stdio` 的内容见下方 SSH 部署示例；它应加载仅 MCP 运行环境可读的 `/etc/sylulive-mcp/runtime.env`，然后 `exec` 独立项目的虚拟环境入口。

若同机仍要求 Go 服务账户无法读取 Hy3 Key，使用受限 `mcp-runner` 账户的 `ssh_stdio`，即使 SSH 目标也是本机。`local_stdio` 只适合已经接受该同机进程信任边界的部署。

## 跨服务器 SSH stdio

MCP 位于另一台服务器时，Go 服务仅启动固定的 `ssh` 子进程并复用 stdio Session：

```dotenv
AI_EXTERNAL_MCP_ENABLED=true
AI_EXTERNAL_MCP_TRANSPORT=ssh_stdio
AI_EXTERNAL_MCP_TOOL_TIMEOUT_SECONDS=90
AI_EXTERNAL_MCP_MAX_CALLS_PER_RUN=1
AI_EXTERNAL_MCP_SSH_HOST=10.0.0.8
AI_EXTERNAL_MCP_SSH_PORT=22
AI_EXTERNAL_MCP_SSH_USER=mcp-runner
AI_EXTERNAL_MCP_SSH_KEY_PATH=/etc/shenliyuan/keys/mcp_ed25519
AI_EXTERNAL_MCP_KNOWN_HOSTS_PATH=/etc/shenliyuan/mcp_known_hosts
```

IPv6 地址使用裸地址，例如 `2001:db8::8`。Go 客户端会在传给 SSH 时添加方括号，不应在环境变量中附带端口或用户名。

目标主机指纹必须**带外**取得，不能只靠 `ssh-keyscan`——它只负责抓取，不证明抓到的就是正确服务器；首次部署时若网络被劫持，会把攻击者指纹写进信任文件。

先在 MCP 主机本地或云控制台读取真实指纹：

```bash
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

把该指纹放进受控部署变量（例如 `MCP_EXPECTED_HOST_FINGERPRINT`），再在 Go 主机写入并**比对后**才落盘：

```bash
ssh-keyscan -t ed25519 -H MCP_HOST > /tmp/mcp_known_hosts.candidate
ssh-keygen -lf /tmp/mcp_known_hosts.candidate

# 人工或脚本比对通过后才安装
test "$(ssh-keygen -lf /tmp/mcp_known_hosts.candidate | awk '{print $2}')" = "$MCP_EXPECTED_HOST_FINGERPRINT"
install -m 600 /tmp/mcp_known_hosts.candidate /etc/shenliyuan/mcp_known_hosts
chmod 600 /etc/shenliyuan/keys/mcp_ed25519
```

不要使用 `StrictHostKeyChecking=no`、密码认证、`ssh ... "任意命令"` 或 `sh -c`。

## 远端运行账户

远端建立专用 `mcp-runner` 账户。该账户不得拥有 sudo、交互式 Shell、生产数据库权限、SYLUlive 主服务文件权限、PTY、端口转发或 SSH Agent 转发权限。

`authorized_keys` 中的主服务公钥使用强制命令：

```text
restrict,command="/opt/SYLUlive_MCP/bin/run-stdio" ssh-ed25519 PUBLIC_KEY_COMMENT
```

`/opt/SYLUlive_MCP/bin/run-stdio` 示例。必须用 `env -i` 清空继承环境后再显式列出所需变量，
不能只做 `set -a; . runtime.env`——那样只是叠加，父进程环境仍会整体传下去：

```sh
#!/bin/sh
set -eu

cd /opt/SYLUlive_MCP
. /etc/sylulive-mcp/runtime.env

exec env -i \
  PATH=/opt/SYLUlive_MCP/.venv/bin:/usr/local/bin:/usr/bin:/bin \
  HOME=/nonexistent \
  LANG=C.UTF-8 \
  LC_ALL=C.UTF-8 \
  HY3_MODE="$HY3_MODE" \
  HY3_API_BASE="$HY3_API_BASE" \
  HY3_API_KEY="$HY3_API_KEY" \
  HY3_MODEL="$HY3_MODEL" \
  /opt/SYLUlive_MCP/.venv/bin/python -m hy3_campus_decision_mcp
```

模块入口不会依赖虚拟环境安装时写入 console-script 的绝对 shebang，因此部署目录从 staging
原子切换到生产路径后仍可执行。

`local_stdio` 传输同样不再继承主服务环境：Go 侧 `localCommand` 会显式设置 `cmd.Env`，只透传
`HY3_` 前缀变量和最小 `PATH`/`HOME`/`LANG`。生产环境仍建议直接使用 `ssh_stdio`。

脚本及环境文件应由管理员管理，并限制为运行账户可执行或读取。SSH 只承载 stdio，不要为 MCP 配置 Nginx、反向代理、TCP 转发或云安全组端口。

## Docker Compose

仓库内的 server 镜像安装了 `openssh-client`，Compose 仅支持通过 `ssh_stdio` 连接外部 MCP。
私钥和 `known_hosts` 由 Compose secrets 只读挂载，不放入镜像或环境变量。复制
`.env.example` 后至少填写：

```dotenv
AI_EXTERNAL_MCP_ENABLED=true
AI_EXTERNAL_MCP_TRANSPORT=ssh_stdio
AI_EXTERNAL_MCP_SSH_HOST=10.0.0.8
AI_EXTERNAL_MCP_SSH_PORT=22
AI_EXTERNAL_MCP_SSH_USER=mcp-runner
AI_EXTERNAL_MCP_SSH_KEY_FILE=/宿主机绝对路径/mcp_ed25519
AI_EXTERNAL_MCP_KNOWN_HOSTS_FILE=/宿主机绝对路径/mcp_known_hosts
```

默认占位 secret 只用于 `AI_EXTERNAL_MCP_ENABLED=false` 时让 Compose 配置可解析，不是有效
密钥。容器内不要配置 `local_stdio`，除非自定义镜像同时只读挂载完整 MCP 运行目录、包装器和
运行环境文件；只注入 `AI_EXTERNAL_MCP_COMMAND` 无法访问宿主机可执行文件。

## 启动与降级

Go 服务启动时会执行 MCP `initialize`、`tools/list` 和私有状态工具检查。只有名称、Schema 和状态声明同时兼容的远端能力才会注册为：

```text
hy3_decision.compare_competitions
hy3_decision.analyze_academic
hy3_decision.plan_student_week
```

MCP 连接失败、远端工具缺失或 Schema 不兼容时，Go Runtime 继续启动并保留本地校园工具；Hy3 工具不会注册。运行期间的连接错误会返回稳定错误码，例如 `external_mcp_unavailable`、`external_mcp_timeout` 或 `external_mcp_constraint_violation`，外层 Agent 应根据已取得的本地确定性数据继续回答。

公开 `/health` 的 `ai.external_mcp` 只返回配置状态、当前健康状态、契约版本、运行模式和
实际注册的生产工具数，不返回命令、主机、账户或环境变量。登录态 `/api/ai/capabilities`
只有在 MCP 健康且对应 Go 包装工具已进入当前 ToolRegistry 时，才会返回：

```json
{
  "features": {
    "hy3_competition_compare": true,
    "hy3_academic_analysis": true,
    "hy3_week_plan": true
  }
}
```

每个 AI Run 最多调用一次独立 MCP，单次调用最大 90 秒，结果最大 128 KiB。计划工具会在 Go 本地复核课表、睡眠和每日时长约束；冲突计划不会返回给模型。

## 运行检查

启用前先确认授权链路的表已经存在。Go 服务启动时会校验，缺表直接拒绝启动 AI Runtime，
不会等到用户点击“允许”时才暴露数据库错误：

```bash
psql "$DSN" -f server/sql/20260719_ai_runtime_rag.sql
psql "$DSN" -f server/sql/20260725_ai_user_permissions.sql
psql "$DSN" -f server/sql/20260726_ai_external_model_permission.sql
psql "$DSN" -f server/sql/20260726_ai_run_consents.sql
```

在启用前分别完成：

1. 在 MCP 主机以 `mcp-runner` 身份运行 stdio SDK 验证，确认状态工具及三个核心工具的 Schema。
2. 在 Go 主机使用专用私钥和 `known_hosts` 进行一次 SSH 强制命令验证。
3. 启动 Go 服务，确认日志出现健康检查成功，或在预期降级时出现稳定错误码而不是进程退出。
4. 使用脱敏测试快照完成一次学业分析和一次冲突课表测试，确认日志与审计记录不含学号、姓名、Cookie、Token、密码或 Hy3 Key。
5. 完成 SYLUlive_MCP 仓库 `assets/live-verification.md` 中的真实 Hy3 验证清单，并把记录填回该文件。
   清单包含四个核心工具的真实调用、非法 JSON 重试、429/401/500/超时/连接中断、
   超长与额外字段、错误来源 ID，以及 `chat_template_kwargs.reasoning_effort` 是否被真实端点接受。
   在该清单全部通过之前，`AI_EXTERNAL_MCP_ENABLED` 必须保持 `false`。

密钥、SSH 私钥或服务器密码一旦出现在聊天记录、终端历史或提交记录中，应立即在相应系统轮换。

## 2026-07-28 生产基线

| 项目 | 冻结值 |
| --- | --- |
| SYLUlive 实现 | `53d8ed5f875e9d7174335b2965def05f377e1bf3` |
| Go 1.25 Linux/amd64 二进制 SHA-256 | `00e49a4177d26a4c6da63fba5f8564b09b7e4995ac633971177b7d78a703f896` |
| SYLUlive_MCP 标签 | `sylulive-mcp-prod-20260728` |
| SYLUlive_MCP 实现 | `765a5b634f18aaa616b3c424462572651c54b034` |
| 契约版本 | `sylulive-hy3/1` |
| 公共 AI 消息上限 | `500` 个 grapheme cluster |
| 不限额学号仓库默认值 | 空；生产值仅允许存在于受控环境文件 |

2026-07-28 23:30 CST 已完成原子部署和独立复核：生产 `/health` 返回外部 MCP
健康、Live 模式和三个已注册工具，匿名 `/api/ai/capabilities` 保持 `401`，启动日志未出现
MCP 连接、工具列表、兼容工具、panic 或 fatal 错误。旧二进制与旧环境文件均已保留为回滚备份，
且旧二进制摘要已复核为 `5040ffd609c98babe1d281e38838ef212f2fee52b6b851b924b67a1f8b409440`。
登录态 `/api/ai/capabilities` 仍需使用专用测试账号完成生产响应验收。
