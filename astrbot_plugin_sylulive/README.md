# SYLUlive × AstrBot 授权业务插件

这是个人部署的 AstrBot 插件。聊天、模型、人格、记忆继续由 AstrBot 管理；插件只调用 SYLUlive 授权 API。QQ 可经用户自行配置的 SnowLuma/其他受支持 OneBot 端进入 AstrBot。本插件不分发 QQ 协议端、不登录学校系统、不读取学校密码，不把聊天转发给 Go AI Runtime。

```mermaid
flowchart LR
  Q[本人 QQ 私聊] --> P[QQ 协议端 / OneBot]
  P --> A[AstrBot 模型与记忆]
  A --> T[本插件：读取与草稿工具]
  T --> G[SYLUlive 授权 API]
  G --> D[(原有社区业务与 PostgreSQL)]
  U[本人登录官网] --> C[授权 / 确认草稿]
  C --> G
```

## 首版边界与真实状态

| 能力 | 本实现 |
| --- | --- |
| 标准设备授权、有效教务资格、一账号一个有效助手安装授权 | 已实现，SQLite HTTP 与隔离 PostgreSQL 测试；官方 Go OAuth 客户端互操作测试 |
| 按权限查看正常普通水帖、搜索、评论、楼中楼上下文、本人公开帖子 | 已实现；列白名单，不增加浏览量；正文内自填个人信息仍可能外发 |
| 查询活跃版块和内置表情 ID | 已实现；SYLUlive 表情与 QQ 表情不互换 |
| 用本人身份发文字帖、文字/表情评论、精确回复评论 | 插件生成不可变草稿，本人在官网逐次确认后同步发布；服务端和本地开关均需开启 |
| 撤销授权、短期 access token、refresh 轮换、重用检测 | 已实现；与 App 登录凭证严格分离 |
| 查询自己的课表、成绩、私信、原始教务资料或替用户登录学校 | **未开放**；API 没有这些 scope，不能通过改提示词或本地配置得到 |
| 自动逛帖、无人确认自动发布、上传图片、点赞、绑定真实 QQ 归属 | **未实现**，不在本首版内 |
| 真实 AstrBot 插件加载、基础 QQ 收发 | 本机 AstrBot 4.29.3 + SnowLuma 2.2.1 已验证；本人授权与公开读取已完成真实 QQ 联调，发布尚未放量 |
| 真实模型选取校园工具并完成业务操作 | 2026-10-30 已验证本轮重新读帖、读取评论及 QQ 回包；验证限于只读，不代表发布、记忆等能力已验收 |

原生 SDK 接口参考 AstrBot 官方源码的 `filter.llm_tool`、`AstrMessageEvent` 与 `StarTools`。本次核对主干 `pyproject.toml` 为 4.29.3；插件兼容范围是待实机验证的声明，不代表范围内每个版本均通过。使用时记录实际固定版本；真实加载不过关不得作为正式可用插件发布。

## 后端和官网准备

先按 [server/README.md](../server/README.md) 与 [web/README.md](../web/README.md) 启动隔离开发环境。后端启动迁移会新增 `integration_*` 表、`refresh_tokens.authenticated_at` 和内容来源列。维护者环境已于 2026-10-30 完成授权与公开读取的生产只读联调；其他安装仍须独立部署并由本人授权。生产迁移、备份、正式放量须走仓库部署流程，不能将一次只读验收当成写入能力已放行。

所有新开关默认关闭。需要同时试验读取、草稿和本人确认发布时：

```dotenv
INTEGRATIONS_ENABLED=true
INTEGRATION_PROPOSALS_ENABLED=true
INTEGRATION_OWNER_PUBLISH_ENABLED=true
INTEGRATION_PUBLIC_ORIGIN=http://127.0.0.1:5173
```

本地网页从仓库根目录启动，**必须显式指向本地 Go**，避免默认代理访问线上：

```powershell
$env:SYLULIVE_API_ORIGIN='http://127.0.0.1:8080'
pnpm dev
```

官网入口 `http://127.0.0.1:5173/web/connected-apps`；个人主页也有“已授权助手”。本地插件的 `server_origin` 配成 **`http://127.0.0.1:5173`**，通过同一个网页代理调用 API。正式环境 API 与官网使用同一个 HTTPS origin，例如 `https://sylulive.online`。客户端拒绝跳转凭证和跨 origin 的验证链接，不能把本地 Go 8080 与网页 5173 混配。

首版只接受当前 `AcademicIdentityBinding` 中 `verification_method=school_profile`、版本 `v1` 或 `undergraduate-preverify-v1`、`verified_at` 非空的身份。`local_declaration`、`legacy_migration`、旧 User 投影不能授权。现有 Web 教务助手的本地身份声明**不自动满足此要求**；未能通过受支持流程补证的真实用户目前不能使用。不要改库伪造真实用户核验；合成数据只用于测试。

## 安装与配置

当前代码在单仓库子目录，不能把本仓库根 URL 当成插件仓库直接导入。

1. 安装用户自己选择的 AstrBot 固定版本和 QQ 协议端，先证明普通 QQ 私聊能收发。
2. 将本目录复制至 AstrBot `data/plugins/astrbot_plugin_sylulive/`，保持 `main.py`、`metadata.yaml` 等文件直接位于该目录。按 AstrBot 插件管理流程安装 `requirements.txt` 并重启/重载插件。
3. 或在本仓库运行 `python scripts/package-astrbot-plugin.py` 得到 `dist/astrbot_plugin_sylulive.zip`，使用支持本地 ZIP 的 AstrBot 管理界面安装。脚本输出 SHA256，固定归档条目顺序、时间与权限；相同源码及 Python/zlib 工具链的输出一致，不受检出文件时间影响。包内只有明确列出的源码/配置/文档，不含 token、缓存、测试数据或协议端。只读安装保持 `allow_proposals=false`。
4. 在插件设置中填写 `server_origin`、消息平台**实例 ID** `owner_platform_id`、本人发送者 ID `owner_sender_id`。QQ 平台填自己的 QQ 号；不能只填通用平台名称 `aiocqhttp` 代替实例 ID。群聊一律拒绝工具执行。
5. 如需草稿，打开插件 `allow_proposals`。在当前 AstrBot 人格/工具集启用本插件的 `sylulive_*` 工具，并使用支持 tool calling 的模型。不要关闭 AstrBot 主模型或把聊天桥接至 Go。

本地发送者白名单只防止本实例误用，不证明真实 QQ 归属。平台约束是“一 SYLUlive 账号一个有效助手安装授权”；手机、电脑、平板 App 登录独立管理，不新增两个登录设备限制。

## 回复展示

0.1.2 通过 AstrBot 原生 `on_llm_request` 为已配置本人私聊追加校园结果展示约定，保留原有人格和原始工具数据。默认用帖子标题、评论内容和本次列表序号交流，不输出 `post_id`、`reply_id`、版本哈希或把数据库编号当楼层。需要继续阅读、引用或生成草稿时，模型仍使用原始准确编号。

例如，日常回复为“《校园话题》的评论里，有同学建议……，另一条回复补充……”。当前请求明确要编号时可显示“帖子 #811、评论 #2013”；明确要原始字段/JSON时再保留技术格式。授权设备代码和审核链接正常展示。连接状态优先显示昵称，不显示账号数据库编号。展示约定只在本人指定私聊生效，不作用于其他发送者或群聊。

0.1.3 增加当前轮读取约定：查看、查询或总结社区内容时，应重新调用阅读工具；“再总结刚才那篇讨论”也不能只改写历史回复。用户明确说只改写/润色、不要重新读取时才允许基于历史整理。对已知帖子、跟进讨论和常用列表请求，插件记录本轮成功的实际接口读取，缺少所需帖子或评论时将最终回答和本轮保存的助手文本改为明确失败提示，不返回旧总结。该检查覆盖明确编号和常见中文跟进表达，不是任意自然语言的完整意图识别；实测范围为 AstrBot 4.29.3 内置 Agent 的非流式回复，流式已发送内容无法由完成钩子撤回。工具调用仍由 AstrBot 模型安排，不新增一套模型或后台自动读帖服务。

### 0.1.3 变更与验收记录（2026-10-30）

- 修复日常回复直接展示数据库字段的问题：优先使用帖子标题和自然语言，连接状态显示昵称；原始编号和版本仍供工具准确引用。
- 修复跟进总结直接复用历史内容的问题：对已知帖子和常见跟进表达检查本轮实际读取，原帖或所需评论缺失时返回明确失败，并同步本轮保存的助手文本。
- 完整插件测试 **47 项通过**，覆盖本人／他人／群聊隔离、命令不重复触发模型，以及无新读取、只读原帖、完整重读和明确仅改写等分支。这是本机验证结果，不代替新提交的 CI 结论。
- 自行完成真实 QQ 测试：普通聊天约 7 秒回复；原句“把刚才那篇讨论再自然地总结一下”约 28 秒回包。严格限定该轮记录，确认 `sylulive_get_post`、`sylulive_replies` 均返回成功；完整 QQ 回复使用自然语言，没有技术编号。
- 测试未发布帖子或评论；临时测试通道和诊断插件已撤除，原身份、授权与权限配置保留。
- 保留问题：曾有一条消息未回复，具体原因尚未确认；后续测试通过不等于已经根治所有消息丢失。

## 用户实际操作

0.1.4 将 `sylulive_replies` 调整为先读取原帖详情，再读取一页评论，返回 `data.post` 和原有 `data.items`。这样模型选择评论工具即可获得本轮完整的原帖上下文；任一读取失败都不返回拼接的旧数据。两次请求仍分别校验同一授权与当前可见性，不增加真人浏览量。此变更不扩大 scope 或发布权限。

1. 在指定平台本人私聊发送 **`/sylu-connect`**。插件直接返回设备代码及官网链接，不依赖模型猜测登录操作。
2. 自己登录官网，核对账号、设备代码与自报安装名称，勾选允许的范围。提案权限默认不勾选。已有连接时，明确同意替换旧连接。
3. 返回私聊发送 **`/sylu-status`**。此命令只轮询一次；未批准/轮询过快会明确提示，稍后再查。不能只看到官网“已授权”就认为插件已经取得凭证。
4. 先让助手“列出 SYLUlive 最近的帖子”，再指定帖子读取评论。也可通过 AstrBot 工具调试界面检查 `sylulive_posts` / `sylulive_get_post` 的真实结果，区分模型未选工具与接口不可用。
5. 需要发布时，助手先读取来源版本，再调用 `sylulive_draft_reply` 或 `sylulive_draft_post`。它返回 `action_id` 和 `review_uri`；此时**尚未发布**。
6. 自己打开官方审核页，核对全文、表情、原帖与目标账号，勾选后点“确认并发布”。草稿保留72小时，一次预览的确认窗口5分钟；超时或另一页面刷新 nonce 后，重新加载再核对。
7. 原帖正文、目标回复或治理状态变化会阻止发布，要求重新生成草稿；浏览/点赞计数变化不会使草稿失效。拒绝草稿也不会发布。
8. 发布状态只认服务端 `state=published` 及返回的真实 `post_id` / `reply_id`。重复确认只返回同一个结果。帖子/评论显式携带来源，正文保留旧客户端也能看到的“助手代发”提示，不发放经验奖励。评论和站内提醒在同一事务提交，精确回复通知对应作者；自回复不提醒，重复确认不重复提醒。外部推送提交后复用现有设置和尽力投递流程，不承诺外部必达。
9. 断开发送 **`/sylu-disconnect`**，或在官网连接管理撤销。网络错误时不能宣称已撤权，应去官网检查。教务换绑/解绑、注销、撤销协议会同步使授权和待发布草稿失效。

以上英文命令为主入口，旧中文词保留为兼容别名。命令处理后终止事件传播，不再让默认模型追加第二条回答。普通聊天和业务工具调用仍由 AstrBot 模型处理。

早期 0.1.1 验证时，校园业务后端尚未启动，连接命令返回服务不可用。后续已完成真实本人官网授权、连接状态和 0.1.3 只读联调，结果见上方验收记录。其他环境仍须按实际接口响应判断，不能仅凭插件加载或合成模型测试宣称已连接。

官网授权和确认发布要求10分钟内真实重新登录。App refresh 或重新生成 JWT 不延长该证明；老版本登录记录没有 `authenticated_at` 时需重新登录。撤销助手不要求10分钟内登录，避免延误止损。

## 凭证与数据

服务端只存 token 摘要；10分钟 access token、7天闲置 refresh token、30天绝对期限。 已轮换的旧 refresh 即使超过原7天期限，保留期内重放仍会撤销同一授权；替换前的旧授权不会影响新连接。插件会隔离旧请求的成功和错误响应，避免清除新连接或新轮换的凭证。插件使用 OS 凭据库，仅接受 Windows、macOS、SecretService/KWallet 内置后端；不使用第三方明文 keyring。无可用凭据库时只存进程内存，命令会提示重启需重新授权。不要把凭证复制进人格、聊天、模型参数、共享配置或日志。

本插件不实现第二套记忆。读取内容可能被 AstrBot、用户所选模型与记忆插件保存；官网撤权可阻断后续请求及发布，无法逆向撤回已交给模型的内容。具体保存/删除见仓库隐私台账及你部署的 AstrBot/模型设置。

## 验证与排错

```powershell
cd server
$env:GOMAXPROCS='2'
go test -p 1 ./internal/handlers ./internal/services -run TestIntegration -count=1
```

真实 PostgreSQL 行锁测试只接受本机专用可丢弃库，并为每个测试新建、清理独立 schema：

```powershell
$env:INTEGRATION_TEST_POSTGRES_DSN='host=127.0.0.1 port=55439 user=YOUR_LOCAL_TEST_USER dbname=sylulive_integration_test sslmode=disable'
go test -p 1 ./internal/services -run TestIntegration -count=1
```

在仓库根目录执行插件与官网定向测试：

```powershell
python -m pip install -r astrbot_plugin_sylulive/requirements.txt pytest pytest-asyncio docstring-parser
python -m pytest -q astrbot_plugin_sylulive/tests
$env:SYLULIVE_API_ORIGIN='http://127.0.0.1:8080'
pnpm exec playwright test web/e2e/connected-apps.spec.ts
```

`test_astrbot_dispatch.py` 需要真实 AstrBot SDK：在隔离环境安装固定 `astrbot==4.29.3` 后运行，未安装时明确跳过。该测试通过 AstrBot 的真实 `ProcessStage` / `StarRequestSubStage` 检查命令成功、失败和拒绝访问路径不会落入第二次模型回复，同时核对英文命令注册。离线事件替身不覆盖这一边界，不能替代此项检查。SDK 导入测试应在隔离目录运行并设置 `ASTRBOT_ROOT`，避免向工作目录写入运行数据。

测试不访问真实 QQ、不调用付费模型、不读取真实学校资料。发布前还必须记录：固定 AstrBot 版本插件加载、本人/他人/群聊隔离、真实 QQ 收发、模型选工具、退出重连和真实账号教务资格覆盖情况。后端 404 先检查开关与服务版本；403 检查资格/scope/近期登录；草稿成功而未发布先检查官网确认和发布开关，不通过绕过授权解决。

参考：[AstrBot 原生工具注册](https://github.com/AstrBotDevs/AstrBot/blob/master/astrbot/core/star/register/star_handler.py)、[AstrMessageEvent](https://github.com/AstrBotDevs/AstrBot/blob/master/astrbot/core/platform/astr_message_event.py)、[RFC 8628](https://www.rfc-editor.org/rfc/rfc8628)、[RFC 7009](https://www.rfc-editor.org/rfc/rfc7009)、[OAuth 安全实践 RFC 9700](https://www.rfc-editor.org/rfc/rfc9700)。
