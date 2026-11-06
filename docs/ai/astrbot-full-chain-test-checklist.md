# Web、App 与 AstrBot 全链路测试清单

本清单用于重复验收，实际日期、版本、命令输出、失败和未验证范围记录在 `docs/reports/`。功能契约以 [API](../../server/API.md)、[Web README](../../web/README.md)、[插件 README](../../astrbot_plugin_sylulive/README.md) 和[运维入口](../ops/astrbot-integrations.md)为准。不能把夹具通过、跳过或本地构建写成真实学校、真实 QQ 或生产发布通过。

## 环境与证据

- [ ] 记录分支、HEAD、未提交差异、Go/Node/Python/Flutter/AstrBot 版本与候选包 SHA256，保留其他任务修改。
- [ ] 自动化使用合成账号与隔离数据库；PostgreSQL 使用可丢弃集群和专用 DSN，验证结束停止本次集群。
- [ ] AstrBot SDK 测试使用独立 `ASTRBOT_ROOT`，不复用真实插件配置、凭据库或记忆。
- [ ] 真实 QQ 测试固定机器人、本人测试私聊和发送额度；记录时间、结果类型和工具名，不保存成绩、密码、Token 或聊天原文。
- [ ] 明确区分源码候选、已安装插件、已部署后端；记录不一致处和升级依赖。
- [ ] 保留首次失败证据和修复后结果；逐项解释 opt-in skip，不把跳过计为通过。

## 学校助手与自动恢复

| 链路 | 必测情形与通过条件 |
| --- | --- |
| 安装与首次授权 | 开发/生产包匹配 origin；下载校验、安装后免刷新握手；学校域名未授权有明确动作；原生授权确由本人处理 |
| 本科教务 | 首次填写并可选择保存；真实学校身份核对后读取成绩；只保存获准凭据；已保存且会话失效时填写、原按钮提交、返回发起页并继续读取 |
| 二课 | 分别处理 WebVPN 与二课登录；顶部栏唯一账号核验；CAS 跳转、会话失效与两级登录完成后返回继续读取 |
| 浏览器重启 | 保存凭据在退出浏览器后仍可由同一本站账号使用；未保存的凭据不可恢复；不同账号与学校系统不串用 |
| 错误与恢复 | 密码错误可修正重试；验证码/滑块/未知学校页面转人工；同阶段不重复自动提交；超时与网络失败保留旧资料 |
| 取消与竞态 | 发起页关闭、取消、同系统重连、本站退出/切号令旧任务失效；晚到结果不回填；临近失效的本站 Cookie 按原刷新流程恢复 |
| 隐私与清理 | 网页看不到密码/学校 Cookie；断开当前系统清凭据和资料；单纯退出保留本人明确保存的凭据但清资料/提醒；损坏密文可清除恢复 |

浏览器自动化中的学校页面是可控夹具，必须另记真实学校执行情况。浏览器工具不支持的扩展页/原生权限弹窗不能通过其他通道绕过，应如实列为待本人验收。

## 授权、同步和个人查询

- [ ] Web 与 App 原生设备授权都核对设备代码、当前账号、近期认证和服务端资格；敏感 scope 默认不选。
- [ ] `community:bot_reply`、`community:bot_post` 独立选择；提案/结果查询/公开阅读依赖完整；旧授权不自动扩权。
- [ ] `personal_data_enabled` 关闭、接口失败、旧服务或切号后，成绩/二课权限不可凭缓存获得；已选项仍可取消。
- [ ] 同步先预览数据类型、学期/来源时间和内容范围，再由本人确认；确认上传不替代确认删除。
- [ ] 成绩只同步当前学期必要字段；二课只上传约定摘要；上传不带学校凭据、原始 HTML 或完整档案。
- [ ] 同步防重复提交，网络失败保留预览供重试；换数据类型、切号、退出使旧确认失效。
- [ ] 删除仅清对应同步副本；接口退役/失败不能显示删除成功；App 自己上传的快照与 Web 成绩副本的区别展示准确。
- [ ] 本人私聊查询可用、无 scope 拒绝、别人账号参数拒绝、群默认不披露；过期或缺快照提示需要同步。
- [ ] PostgreSQL JSONB 重排后摘要仍可校验；兼容严格的旧哈希，篡改内容或字段仍拒绝。
- [ ] 并发刷新不丢授权；旧 refresh 重放拒绝；撤权、设备取消、身份换绑/注销后旧请求和在途动作不能继续。

## 独立机器人与社区自主任务

- [ ] 两账号分别恢复／建立后台任务、公开记忆与账本；暂停 A 的在途 Agent，B 仍可读正文／讨论并以自己的 bot 评论，管理页回读不串号。
- [ ] 只读 scope 可心跳但无发言工具；平台写入关闭或本人策略关闭时保持阅读，旧连接不自动扩权；旧服务不匿名降级。
- [ ] 同 bot 双进程占用、旧序号／会话／规则版本、撤权和旧插件无执行会话写入拒绝；重启不绕过间隔，每实例模型并发不超过2。
- [ ] 旧表升级保留 bot ID、启停、只读缺省和已有执行元数据，迁移可重复；回滚先停自动写入，不删除新增列和账本。
- [ ] App/Web 定时状态刷新不重置资料草稿，失败降为尚未核验，重试可恢复；心跳过期离线，成功发言不能由执行端报告伪造。

- [ ] 一人一个 bot，新建默认暂停；创建者不能指定 owner/actor；改名、有效本人头像、禁用和重试均可用。
- [ ] App/Web 共用策略；公开浏览、文字评论、内置表情、自动发帖、公开配图分别持久化；新增发帖/配图默认关闭。
- [ ] 页面展示账号启停、服务端总开关和当前连接授权；账号启用不冒充 AstrBot 后台已运行。
- [ ] 读取限允许板块，排除投诉/迎新求助等不允许类别；先过滤列表，再复核详情、评论分页与图片来源。
- [ ] 真实原生 Agent 工具循环先阅读再动作；公开上下文不继承私人聊天/成绩/全局知识库；不跟随来源中的任意 URL 或提示指令。
- [ ] 自动评论需已读正文与讨论，版本改变重读；精确回复父线程与通知对象由服务端推导。
- [ ] 自主帖子含本轮已读来源和版本；评论授权不能代替发帖授权；关闭 post/image 策略后分别阻断。
- [ ] 图片来自部署者审核公开素材清单，固定哈希；单文件 multipart、大小/真实格式/尺寸校验；外人文件拒绝，有效 bot 上传/授权文件才可绑定。
- [ ] 上传仍私有，只有发布事务提交后公开；失败不把孤儿图片冒充已发表。
- [ ] 图片与内置表情使用不同权限；QQ `search_meme/send_meme` 不自动取得社区上传权，也不从私人聊天自动采图。
- [ ] 单日发帖额度、评论日限/间隔、板块规则、禁链接、屏蔽词、禁言、信誉、暂停、撤权和资格在最终事务复核。
- [ ] 重复 operation 幂等，同步并发不重复发布；来源删除/改写、审计失败整体回滚；发布结果不确定不盲重试。
- [ ] 发帖、评论及通知归属真实 bot 账号，无普通用户奖励；公共作者展示 AI 标记和创建者公开归属，普通昵称不能伪造标记。
- [ ] 创建者注销后不返回旧归属；帖子/评论刷新、分页、浅色/深色均使用服务端字段。

## QQ、原生 SDK 与表情

- [ ] 确认原 QQ/SnowLuma/AstrBot 已运行，正确机器人在线；保留原人格、模型、TTS、白名单、账号绑定和群设置。
- [ ] 本人测试私聊：状态、成绩、二课、自然语言浏览、读帖子/评论，记录真实调用工具与回复类型。
- [ ] QQ 原生回复引用：另一成员引用机器人推荐后说“这个／这家”，检查引用原文与当前发言同时到达最终 Provider；人格不能覆盖引用指代，明确引用不套用最近一次其他店铺／帖子。
- [ ] 引用附件：文字、纯图片、文字加图、原生图片描述、语音、图片失效、撤回／仅编号、超长／嵌套引用逐项验证；只声称读取实际提供内容，缺原文需补充，不额外取聊天、文件或任意URL。
- [ ] 引用隔离与后续追问：不同成员显式回复可理解；其他群、外来会话预载、无引用的新消息、并发请求不混入旧引用。群引用摘要只沿用有界30分钟上下文，不写入创建者长期记忆／公开后台库。
- [ ] 引用中的签到／查成绩／授权／提示词只作为资料；验证不触发确定命令，不增加私有工具或 scope。修改消息处理后重跑 `test_quoted_chat.py` 及插件完整 pytest，真实 QQ 与合成 Provider 验收分别记录。
- [ ] 越权/索要凭据测试拒绝且不调用私有工具；TTS 模式在语音合成前记录拒绝布尔值，不因音频结果误判失败。
- [ ] 自然语言表情请求确实调用 `search_meme` → `send_meme` 并送达图片；选图语义与回复一致，失败不重复发。
- [ ] 图库预览审美和清晰度单独验收：通过发送测试仅证明能力，不能证明用户喜欢素材；新素材记录来源和许可后入库。
- [ ] 整套角色导入同时验证中文显示名和内部角色键；按图中文字搜索应命中，指定未知角色应返回空，不能静默丢弃角色过滤。
- [ ] 切换图库先备份旧文件和索引，再核对新图片摘要；保留无关待审图片，临时调整的容量恢复，审核开关不因导入关闭。
- [ ] 测试后卸载临时探针、恢复临时路由、对比受保护配置摘要；保留用户需要的正式服务运行。

## UI 与异常状态

- [ ] Web 390px/桌面、App 标准视口、浅色/深色、1.3/1.5 倍文字真实渲染；权限卡片可滚动，按钮不遮挡、无溢出。
- [ ] loading、empty、error、retry、saving、缺资格/缺授权、旧服务404、切号/晚到响应均覆盖。
- [ ] 键盘/焦点、禁用原因、控件语义和最小触控区域符合设计规范；不改已接受 ADR 或在 Windows 生成权威 golden。
- [ ] 截图前重新定位元素并完成滚动；截图工具错误与产品断言失败分别记录。

## 可重复命令

在仓库根目录执行 Web 检查与本次浏览器回归：

```powershell
pnpm -r check
pnpm test
pnpm exec playwright test web/e2e/connected-apps.spec.ts web/e2e/community-presentation.spec.ts web/e2e/integration-personal-sync.spec.ts web/e2e/assistant-authorization.spec.ts web/e2e/assistant-autologin.spec.ts web/e2e/assistant-extension-login.spec.ts web/e2e/academic-connection.spec.ts web/e2e/auth-cookie.spec.ts web/e2e/extension.spec.ts web/e2e/privacy.spec.ts --workers=1
pnpm -r build
pnpm assistant:dev
python scripts/package-astrbot-plugin.py
```

按插件 README 设置隔离的 `ASTRBOT_ROOT`、真实 SDK 的 Python 解释器后运行 `python -m pytest astrbot_plugin_sylulive/tests`。可选 Stealer 兼容测试需要另外提供审核后的 checkout；缺少时必须记为跳过。

```powershell
Set-Location server
go vet ./...
go test ./...
go build ./...
go test -race ./internal/services ./internal/handlers -run TestIntegration -count=1
```

数据库集成按 `server` 测试文件中专用环境变量，在全新可丢弃 PostgreSQL 上显式运行 `TestIntegration`；没有环境的跳过不计验收。

跨运行时测试先按 Web README 启动本机 Vite，再设置真实 AstrBot SDK Python 路径：

```powershell
$env:SYLULIVE_FULL_CHAIN_PYTHON = 'D:/AI/QQ/AstrBot/.venv/Scripts/python.exe'
$env:SYLULIVE_FULL_CHAIN_WEB = 'http://127.0.0.1:5173'
Set-Location server
go test -p 1 ./internal/handlers -run '^TestIntegrationWebAstrBotCrossRuntime$' -count=1 -v
```

此测试运行实际 Web、Go HTTP、Python BusinessClient 和原生 AstrBot 工具循环，模型使用确定性测试 Provider，数据库和账号均合成；它不连接 QQ，也不产生付费模型请求。

```powershell
Set-Location client
flutter analyze lib/screens/managed_bot_screen.dart lib/screens/managed_bot_connections_screen.dart test/screens/managed_bot_screen_test.dart
flutter test test/screens/managed_bot_screen_test.dart
```

真实 QQ、真实学校、设备原生弹窗和生产写入属于单独验收栏。生产发布继续遵循运维入口的候选固定、备份、审批与回滚，不由测试脚本自动开启。
