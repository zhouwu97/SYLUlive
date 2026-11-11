# SYLUlive Server

server/ 是沈理校园的 Go 后端，负责 App 账号、社区、竞赛、通知、反馈、管理、安全中心和公共服务。它还保留迁移期教务兼容入口，但新版个人教务访问不应默认依赖该路径。

## 架构边界

- App API 通过 Gin 提供 HTTP 接口，业务状态和权限数据存储在 PostgreSQL / pgvector。
- Nginx 负责公网 HTTPS、反向代理、静态文件和边缘限流；Go 服务默认监听 0.0.0.0:8080，生产不应绕过 Nginx 暴露该端口。
- Python RAG 服务处理允许的校园公共知识；个人教务凭据、Cookie 和原始学校响应不得进入 RAG。
- python-edu-service 是迁移期兼容组件。SCHOOL_AUTHORITY_RETIRED、SCHOOL_ACADEMIC_ROUTES_RETIRED 和客户端能力探测共同决定旧链路状态。

## AstrBot 个人授权插件

逐账号后台运行由常驻 AstrBot 执行，Go 使用 `managed_bots.revision/runtime_json` 保存规则版本和最新非正文状态。`/api/connected-apps/bot/runtime` 只返回本人状态，集成心跳 `/api/integrations/v1/bot/runtime` 只接受有效绑定及公开阅读授权；执行占用与策略版本在发布事务中再次校验。新列为兼容新增，旧 bot 默认不获得写权限；接口与迁移／回滚顺序见 [API](API.md) 和[运维入口](../docs/ops/astrbot-integrations.md)。

新增集成以 AstrBot 为主助手，Go 提供限定 scope 的公开社区读取、草稿、本人确认发布与撤销。无需打开 Go AI 模型或 MCP 开关。安装、配置、准入限制与真实联调状态以 [插件 README](../astrbot_plugin_sylulive/README.md) 为入口。

`INTEGRATIONS_ENABLED`、`INTEGRATION_PROPOSALS_ENABLED`、`INTEGRATION_OWNER_PUBLISH_ENABLED` 默认全关；独立机器人自动评论开关 `INTEGRATION_AUTO_REPLY_ENABLED` 默认关闭，依赖集成及提案开关，采用新 `community:bot_reply` scope，不自动扩展旧授权。新增 `managed_bots` 表，App/Web 本人管理一个独立 bot 用户；创建、编辑、启用和暂停使用当前有效登录。后两项依次依赖前项。启用时必须配置 `INTEGRATION_PUBLIC_ORIGIN` 为官网 HTTPS origin（本地开发允许回环 HTTP）；该地址与插件 `server_origin` 保持一致。新增设备请求、授权、凭证摘要、草稿、审计与限流表及内容来源列；迁移需使用原有备份/发布流程，不能先开生产开关再补验收。

官方网页入口 `/web/connected-apps`；查看连接请求、预览本人草稿、拒绝及撤销使用当前 App 登录即可；批准新授权、修改现有权限、创建／编辑／启用机器人及确认发布均复用当前有效登录，不额外要求密码验证。`POST /api/auth/reauthenticate` 只校验当前登录用户的密码与预期账号，更新当前刷新会话族的近期认证；不新建登录、不更换Cookie、不延长令牌、不影响其他设备。失败限流和成功审计沿用现有安全设施，密码和令牌不进入日志。助手授权独立于 App 登录设备；QQ 平台实例和发送者白名单由插件本地检查，不作为后端身份。教务资格、scope、用户状态及内容源版本由后端当前数据复核。正常 App 的发帖/评论仍使用原规则，助手复用核心额度与评论统计事务。

## 本地运行

机器人管理通过 App/Web 共用的 `/api/connected-apps/bot` 新建暂停账号、编辑名字和本人公开头像、保存社区阅读／文字评论／内置表情权限以及板块、屏蔽词、链接和限频规则。规则存入兼容新增列 `managed_bots.policy_json`，旧记录默认只读；认证 Reader 和最终发布事务均执行当前规则。公开作者仅显示服务端确认的AI标记及创建者公开ID／昵称。App内也能完成设备代码核对和scope授权，不必跳网页。详细契约及部署顺序见 [API](API.md) 和 [集成运维入口](../docs/ops/astrbot-integrations.md)。

准备 PostgreSQL 和环境变量后：

~~~bash
go run ./cmd
~~~

默认地址为 http://localhost:8080。也可以使用仓库根目录的 Docker Compose 运行完整依赖。

## 关键配置

生产启动前必须配置 JWT、数据库、安全中心和代理信任边界。安全相关变量包括：

- TRUSTED_PROXY_CIDRS
- SECURITY_EVENT_HMAC_SECRET
- SECURITY_BLOCK_ENABLED
- SECURITY_SOURCE_ATTRIBUTION_VALID_FROM
- SECURITY_IP_V4_DB_PATH、SECURITY_IP_V6_DB_PATH（离线 IP 归属地库）
- SCHOOL_AUTHORITY_RETIRED
- SCHOOL_ACADEMIC_ROUTES_RETIRED

以 .env.example、配置加载代码和部署文档为准，不要把开发默认值直接带入生产。

### 社区 Agent 只读增量

`AI_COMMUNITY_READ_ENABLED=false` 默认不注册新增社区工具。隔离开发环境显式启用后，已有 Go Runtime 可用 `community.list_feed`、`community.search_posts`、`community.get_post`、`community.list_replies`、`community.get_reply_context`、`community.list_stickers`。同时需要已有 AI 配置和支持工具调用的模型；若使用 Agent 能力白名单，也需放行相应工具。关闭开关并重启后，新请求无法使用这些工具。

本增量只读取正常状态的普通水帖，不包含集市、投票、隐藏或删除帖子。工具只选择允许的文字与定位字段，不加载作者资料、联系方式列、图片或上传地址；不走会增加浏览量的 HTTP 详情流程。内置表情与现有评论校验使用同一资源目录。正文截断会明确标记，`source_version` 基于完整选定内容计算，不含浏览量、点赞数、回复数或 `UpdatedAt`。

帖子列表按 ID 降序，评论列表按 ID 升序，最多每页 20 条；响应包含 `items` 和 `next_after_id`，游标为 0 表示已到末页。表情目录按 ID 升序，使用字符串游标 `next_after_sticker_id`，空字符串表示末页。评论上下文包含所属帖子、当前评论及适用的根评论、精确回复目标；已删除根评论和目标仅返回墓碑。

创建 Run 可传 `post` 或 `reply` 引用，格式见 [API 说明](API.md#社区页面上下文只读增量)。服务端验证当前可见性，并在模型生成前通过已有审计工具读取；已缓存的社区结果在幂等重放前复核来源。帖子和评论文字仍可能包含用户自填个人信息；列白名单不是自动脱敏。外部模型接收范围、工具审计保存与尚未完成的撤回边界见 [隐私数据台账](../docs/privacy-data-inventory.md)。

本节描述 Go Runtime 的社区只读工具增量，不包含 AstrBot 集成的机器人、草稿与发布事务；后者按上文配置与插件 README 独立授权和验收。不得把只读工具增量视为 M1/M2 完整验收。生产开放前仍需完成来源删除传播、运行中授权代次、留存治理及专门验收；已经发给外部模型的数据无法由本地删除逆向撤回。

### 安全预警 IP 与离线归属地

仅需管理员处置的预警保存 IP 密文；普通登录、验证码等审计流水仍只保存来源摘要。管理员安全接口可查看预警 IP 和国家／省市归属地，普通用户接口不返回这些字段。历史摘要不可逆，升级前的记录显示「未记录 IP」。

本地运行前在 `server/` 执行 `go run ./cmd/install_geoip`，安装并校验固定版本的 IPv4／IPv6 离线库。Docker 构建自动执行相同步骤并携带数据文件；运行期间不下载数据，也不会向第三方发送用户 IP。systemd／独立二进制发布须一并携带 `data/geoip/`，或用上述环境变量指定可读路径。缺失或损坏的库会在安全中心显示不可用／降级，其他安全采集与处置继续工作。来源、校验值、许可与更新方式见 [离线库说明](data/geoip/README.md)。

## 数据库与迁移

迁移由服务端启动流程和仓库迁移脚本共同维护。生产执行前先备份 PostgreSQL，并在独立环境验证升级、回滚和安全表清理。不要直接修改生产表结构绕过迁移。

资料“获赞”按当前有效点赞事实查询，与“收到的赞”明细保持同一口径，见 [API](API.md#6-消息与通知-messages)。用户/关联作者批量查询共用一次汇总；点赞表启动迁移增加 `idx_like_target(target_type,target_id)`，原唯一索引保留。数据库 `users.total_likes_received` 只保留兼容写入和校准快照，历史错值不影响新版接口。旧校准命令现在默认只预览，显式连接与写入步骤见 [运维入口](../docs/ops/backend.md#获赞兼容快照校准)。

签到补签卡规则见 [用户接口说明](API.md#2-用户与个人中心-user)。迁移 `20261025_04_checkin_makeup_card_schedule` 在启动时按历史签到事实重建「每段连续签到第 7 天首张、之后每隔 14 天再发一张」的汇总，保留额外发放数量并按补签事实保留已使用数量，不修改用户经验或经验流水。迁移 `20261109_05_checkin_streak_reconciliation` 在启动时自动校验全量账号的连续签到事实与汇总一致性，对不一致的账号重算修正并写入审计流水；也可通过超级管理员接口 `POST /api/admin/checkin/rebuild-all` 或命令行 `go run ./cmd/reconcile_checkin_streaks [--inspect|--apply]` 随时执行对账与修复。若旧规则或补签合并前已经发放的奖励多于重建结果，差额转入 `makeup_cards_granted` 保留，后续重建不重复补发。整批重建与迁移标记在同一事务内，可失败重试；也兼容已存在 `20261025_03_checkin_weekly_makeup_cards` 标记的数据。升级期间应停止旧版实例写入签到；回退旧版前应同步恢复备份中的签到事实和汇总，避免旧版周期与新版余额混用。

## 测试

~~~bash
go test ./...
go vet ./...
go build ./...
~~~

涉及认证、教务边界、上传、MCP、安全事件和管理员接口的修改，需要同时运行对应的集成测试。

## 接口文档

公开 `/terms`、`/privacy` 从 App 的 `client/lib/legal/legal_documents.dart` 导出并嵌入 Go 二进制，二进制和容器部署不再依赖当前工作目录的 HTML 文件。文档确认版本必须与 `models.LegalDocumentVersion` 一致，旧版本同意记录保留并按现有门禁重新确认，不自动改写为新同意。正文维护、网关路由、验证与回退见 [公开法律文档运维](../docs/ops/public-legal-documents.md)。

表情包投稿使用新增的 `community_emoji_packs` / `community_emoji_pack_assets` 表和现有上传卷内的私有 `.emoji-submissions` 目录；启动 AutoMigrate 创建新表，维护任务清理过期孤儿目录。不得把该目录单独暴露为静态文件。配套接口、审核和额度见 [API](API.md#表情包导入投稿与审核)，备份、验证和回退见 [运维说明](../docs/ops/emoji-packs.md)。

免费商城增加 `emoji_creators` 独立创作者申请/权限表及作品版本、封面、图标、公开标签等兼容列。新投稿在入口及提交事务复核 active 权限，管理员通过新作品时再次复核；历史投稿不自动赋予作者权限。派生图片继续存于私有上传子目录，经过授权接口读取，不改变旧 Manifest Hash。版本与发布门禁见 [实施方案](../docs/design/emoji-creator-store-plan.md)。

- [API 总览与路由状态](./API.md)
- [仓库部署总入口](../DEPLOY.md)
- [隐私数据台账](../docs/privacy-data-inventory.md)

## 教务绑定自动登记

原客户端绑定链路通过 `/api/student-identity/verify-session` 临时使用学校会话核对真实学号，仍受既有身份写入开关约束。配置／本机声明不直接授予资格；最终事务复核配置版本、账号、协议和在途尝试，解绑同时撤销匹配配置。完整契约与失败恢复见 [API 教务章节](API.md#3-教务系统-edu)。需同时部署 Python 内部核验接口，不批量手填可信身份。

## 食堂展示标签

管理员在食堂运营中设置位置和展示标签。手动标签保存在 `canteens.display_tags`（可空文本列），NULL 使用评价自动汇总，JSON 空数组隐藏展示标签；原始评价不变。服务启动的 AutoMigrate 添加该向后兼容列；旧数据默认为 NULL。回退代码会忽略手动标签并继续自动汇总，保留该列可在重新升级后恢复设置。发布前在隔离数据库验证升级、权限、榜单缓存和回退，生产迁移遵循备份与部署流程。
