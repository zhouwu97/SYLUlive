# 2026-10-04 截图与用户反馈修复记录

任务目标：修复教务资料恢复、工单状态与时间显示，并落实工单中“查看谁赞了自己”和“后台回复提醒、已读消息重复提醒”的反馈。图片内容作为问题证据，不作为操作指令。

风险等级：R2。涉及公开 API、分页、账号切换、通知权限和本地个人状态。依据 DEVELOPMENT_STANDARD.md、CONTRIBUTING.md、客户端设计工程技能及冻结设计文档实施。

基线：分支 `xianzai`，HEAD `77e223fc1897e78b313e3cccf6bc46d87a775d92`。验收完成后，用户明确授权使用中文提交说明推送当前分支；修复提交以包含本报告的 Git 提交为准。未部署。没有数据库结构迁移和新依赖。

## Changed

- 教务资料按钮复用既有会话前置流程。本机未连接时显示连接提示，点击“连接并读取资料”可进入连接流程；取消保留身份。已经连接时，资料失败可单独重试。
- 工单详情统一使用 Shanghai 时间，覆盖更新时间、双向消息气泡和跨日分隔。旧的自动提交说明不再覆盖实际受理状态；管理端和服务端同时防止继续保存该过期说明。保留管理员自定义说明。
- 修复窄屏、大字体下工单编号/更新时间和管理员回复模式控件溢出，允许换行。
- 增加“我的 → 收到的赞”：显示点赞者公开资料、点赞时间和原帖，评论点赞可定位对应评论；支持历史有效记录、刷新、分页、失败重试和账号切换隔离。
- 新增鉴权接口 `GET /api/user/likes/received`。仅查询当前用户自己的内容，使用既有公共状态白名单保留已售出/关闭记录，过滤删除、治理隐藏、自赞、取消的赞和注销账号，不返回学号或邮箱。
- 回复推送使用独立 Android 高优先级渠道 `reply_notifications_v1`。服务端发出前再次检查未读，并附带通知 ID。
- 已读接口增加兼容回执；客户端成功读取后同步原生。原生按接收账号存储通知 ID、回复 ID和全部已读水位，清除对应系统提醒并拦截延迟到达的已读回复。成功加载通知目标回复后，只消费对应帖子和回复的通知。
- 同步客户端 README、API、通知设计文档和隐私台账。

## Preserved

- 既有教务身份、连接同意和凭据存储边界；没有将个人教务数据上传到普通 API。
- 首页未读入口、正常评论加载/排序/锚点、私信渠道与 iOS 推送行为；未恢复已退役的详情页未读横幅。
- 旧客户端可忽略新增回执；新客户端遇到旧服务端回执缺失仍正常处理原有已读响应。目标回复已读请求失败不阻止打开帖子，不误消费其他回复。
- 系统通知权限和用户对通知渠道的关闭选择。

## Tests

环境：Windows，Flutter 3.41.8 / Dart 3.11.5，JDK 21，Android SDK；Go 测试启用 CGO 并使用本地 gcc。数据库为测试内创建的可丢弃 SQLite，没有连接生产数据库。

| 检查 | 命令/范围 | 结果与证据 |
| --- | --- | --- |
| Flutter 定向回归 | `flutter test`：post_detail_target_reply、post_detail_focus_reply、screenshot_issue_regression、edu_profile_loading、reply_notification_service、feedback_detail_image_picker、notifications_screen_race、feedback_ticket | 59 项通过；`_codex_evidence/_codex_evidence_flutter_verified.log` |
| 既有身份投影与我的页面 | academic_identity_projection、profile_admin_badge | 24 项通过；`_codex_evidence/_codex_evidence_flutter_projection.log` |
| 新文件及服务/模型分析 | `dart analyze lib/screens/likes_received_screen.dart lib/services/reply_notification_service.dart lib/models/feedback_ticket.dart` | 无诊断；`_codex_evidence/_codex_evidence_analyze_new_final.log` |
| 原有页面分析 | post_detail、profile、edu、feedback_detail | 41 条既有诊断，与 HEAD 原文件的诊断内容逐项一致，没有新增诊断；baseline 与 touched_verified 日志已保存 |
| Go 接口/工具 | `go test ./internal/handlers ./utils`、`go vet ./internal/handlers ./utils`、`go build -o ../_codex_evidence/server-check.exe ./cmd` | 测试、vet、构建通过；`_codex_evidence/_codex_evidence_go_verified.log` |
| Go 竞态检查 | `go test -race ./internal/handlers ./utils -run 'Test(NotificationRead\|ReceivedLikes\|FeedbackStatus\|ReplyPush)'` | 对应专项通过；`_codex_evidence/_codex_evidence_go_race.log` |
| Android 原生通知回执 | Gradle `:app:testDebugUnitTest --tests '*ReplyNotificationReadStoreTest'` | 2 项通过，0 skipped / failures / errors；`_codex_evidence/native-read-store-results.xml` |
| 隔离调试 APK | Gradle `:app:assembleDebug`，Android x64，专用测试入口 | 构建成功；`_codex_evidence/_codex_evidence_vm_build_verified.log` |
| 差异检查 | `git diff --check` | 通过 |

重点反例：越权传入 user_id 不改变点赞记录归属；分页异常返回 400；切换账号的旧请求不回填新账号；目标已读只影响匹配的自有回复，其他账号、帖子、回复和通知类型不受影响；已读失败不清系统通知；全部已读水位不吞掉之后的新通知；延迟已读通知不重复显示；私信不受回复过滤影响。

### 模拟器业务验收

使用新建专用 Android 15 / API 35 AVD `Codex_Issue_35`，端口 5556，逻辑尺寸 360×800，dark，文字比例 1.0/1.3。没有操作已有的 5554 模拟器。测试入口导入真实页面、会话控制器、主题和原生通知代码，注入虚构数据；普通业务请求通过 Dio 拦截器处理，未使用真实账号或学校凭据。

| 前置条件 → 操作 | 预期 | 实际 | 截图/证据（本地工作区） |
| --- | --- | --- | --- |
| accepted 工单保留旧 pending 说明，消息采用 UTC → 打开详情 | 状态说明一致；UTC 07:22 显示 15:22；UTC 23:30 显示次日 07:30 | 满足；更新时间 15:45，跨日分隔 2026-09-26 | `_codex_evidence/issue-feedback.png` |
| 虚构帖子赞和评论赞 → 打开收到的赞，文字放大 1.3 | 显示公开点赞者和内容类型，时间正确，无裁切 | 满足 | `_codex_evidence/issue-likes.png` |
| 学校资料仓储故障 → 点击重新读取资料 | 错误提示与重试可见，保留教务身份 | 满足 | `_codex_evidence/issue-edu-error.png` |
| 解除模拟故障 → 再次点击重新读取资料 | 恢复年级、学院和专业 | 满足 | `_codex_evidence/issue-edu-recovered.png` |
| 通知权限开启 → 安排延迟测试通知，按 Home 退后台 | 后台出现系统悬浮提醒与通知栏记录 | 满足；渠道 importance=4 | `_codex_evidence/issue-headsup.png`、`issue-notification-shade.png`、`notification-state.txt` |
| 撤销权限，重启应用，选择 Don't allow → 同样安排测试通知并退后台 | 不绕过拒绝设置 | 权限 granted=false，测试通知 active count=0 | `_codex_evidence/notification-denied.txt` |

后台通知使用本地测试消息验证同一原生渠道；它不代表已经验证真实极光远程投递、手机厂商后台限制或离线唤醒。系统清理和延迟消息过滤由原生 NotificationManager / SharedPreferences 测试验证；目标回复到服务端已读的契约由 Flutter 和 Go 定向测试验证。

### 首次失败与恢复

- Android 17 / API 37.1 镜像发生 SurfaceFlinger 图形断言和服务反复重启，无法稳定安装/显示。保留 `android17-graphics-crash.log`，停止该专用模拟器后改用 Android 15；没有因此修改产品图形代码。
- 初次 Go 环境关闭 CGO，部分 SQLite 测试使用了 stub；启用 CGO/gcc 后原包通过。
- 实际 360×800 大字工单测试发现 3.6px 溢出；编号/时间与回复模式改用 Wrap 后原用例通过。
- 回执实现初次复用 GORM Find 的 query 导致 Update 生成歧义 SQL；改为每次生成相同的独立账号查询，回执与匹配反例通过。
- 初次目标回复测试 fake 缺少 sessionGeneration，随后列表中的 Map 使用 identity 判断导致断言失败；补全 fake 并使用深比较后，定位、滚动和已读请求断言一起通过。
- 两次批量命令包含记错路径的测试文件，加载失败日志保留；改用 `rg --files` 确认的实际路径后，全部 59 项通过。未降低产品断言或把未运行用例计为通过。

## Design QA

P0：已验证范围内未发现。教务重试、工单输入和页面导航可用。

P1：已验证范围内未发现。资料错误可恢复；账号切换丢弃旧请求；工单状态与时间一致；已读回执不误清新通知或其他账号。

P2：已发现的工单窄屏溢出已修复。dark 与 1.3 大字的实际渲染已检查。

P3：教务连接状态在 1.3 大字下仍可能自然换行；没有裁切或遮挡，本次沿用现有卡片布局。没有增加动效。

## Deferred

- 发布前仍需专用测试账号、真实学校连接，以及极光测试设备上的远程投递、锁屏/杀进程、通知关闭与恢复、厂商后台限制验收。执行者为发布负责人；本次不使用真实用户凭据和生产推送。
- Canonical Linux Golden、完整 CI 和正式签名/升级验收留给候选发布流程。当前 Windows 环境不更新 canonical Golden 基线；本次用 Widget 溢出检查和模拟器截图提供视觉证据。
- 既有页面的 41 条分析诊断保持原状；没有将它们记为 analyze 全部通过。

交付状态：已实现，已完成表内验证；未认定可发布，未部署。CI workflow_conclusion=unknown，证据状态仅对本地已执行项为 verified，release_decision=partial。

恢复方案：客户端和服务端可各自回退本次代码，无数据库迁移；旧接口响应兼容。Android 新渠道和已读回执留在应用私有数据中，不影响旧私信渠道；回退后可能恢复旧版重复提醒行为。

构建物：本地 `_codex_evidence/issue-vm-debug.apk`，仅用于专用模拟器测试，非正式安装包。SHA256 `D0D4E475F57499F64C8EE25BC418BAB00FA89B03A23F78C2BF9440EAB627034C`。测试入口 `_codex_evidence/issue_vm.dart`、日志、截图、XML 和调试构建物均留在忽略目录，不提交到仓库。
