# 鸿蒙迁移测试矩阵

| 范围 | 检查项 | 当前状态 |
| --- | --- | --- |
| Android | `flutter pub get`、全量测试、Debug APK | 标准依赖使用官方 JPush 3.4.6，Debug APK 已重建；验证后已切回 OHOS 覆盖；全量测试仍有 1 个迁移前 TLS 断言失败 |
| Ohos 环境 | `flutter doctor -v`、`ohpm --version`、`hvigorw --version`、`hdc list targets` | SDK、ohpm、Node、hvigorw 已通过；`127.0.0.1:5555` x64 API 24 模拟器在线 |
| Ohos 构建 | `flutter build hap --debug --dart-define=APP_PLATFORM=ohos` | 最新 x64 signed HAP 已生成并使用 `hdc install -r` 覆盖安装，SHA-256 为 `9CECB8F6BE5B745ED36A637B12F45749AFBEB44EFFA9C90E5E82C60A9580D4E2` |
| Release 产物 | Android APK、HarmonyOS arm64/x64 HAP | 三个 Release 产物均已生成并完成架构/签名包检查；产物位于 `build/release/`，Android APK SHA-256 `7098CA516A82DE9EF79DEF432AFE6A746D5D714821639944046EFADD7A57F468`，arm64 HAP SHA-256 `00F7C7B7885627E8DD4CEE2D1E7D8EFEEB552B12CB08507A6266E3EDFC4E217E`，x64 HAP SHA-256 `DD288AE884B98409F51B5657B9EF829AE598A578A3186961DCABB6645C8861E9` |
| 核心业务 | 首装、冷启动、登录、Token 恢复、退出、课表、学期/周次切换 | 首帧、登录恢复、教务绑定恢复、教务状态接口、真实课程、周次切换、课程详情和缓存重启恢复通过；手动退出清理与重新绑定仍待验收 |
| 竞赛闭环 | 推荐、详情、加入计划、计划同步 | 分类、总览、列表、用户状态和筛选已在 x64 模拟器通过；当前真实数据为 0 条，详情和加入计划同步待有数据后验收 |
| 鸿蒙能力 | 深链、卡片、实况窗、应用接续、扫码权限、错误码、退出清理 | 深链、接续桥接、三张服务卡片和阶段 9 实况窗代码均已接入并通过定向测试/构建；最新 HAP 已启动且日志无 `MissingPluginException`、未处理异常或 Fatal；阶段 8/9 交互仍待用户现场验收；阶段 10 Scan Kit 入口保持关闭，课表分享码导入缺少后端 API；真实跨设备接续需第二台设备 |
| 自适应 | 手机、平板横竖屏、宽屏双栏 | 模块声明覆盖 phone/tablet/2in1；竞赛中心 840dp 以上双栏，窄屏单列；实体平板/2in1 验收待补 |
| Android 回归 | 极光、通知、小组件、课程提醒、APK 更新、保活 | 每次平台服务变更后回归 |
# 鸿蒙验证矩阵

## 构建目标

- DevEco Pura 90 模拟器为 `x86_64`，使用 `ohos-x64`：
  `./tool/build_harmony.ps1 -Mode debug -TargetPlatform ohos-x64 -SkipTests`
- 实体 HarmonyOS NEXT 设备通常为 `arm64-v8a`，使用默认 `ohos-arm64`。
- 安装前用 `hdc shell param get const.product.cpu.abilist` 确认 ABI；若 HAP 的 `libs/` 目录架构与设备不一致，系统会拒绝安装。
- 构建脚本会在 ArkTS 编译前修正 Flutter 嵌入层的 ICU 原生库目录；否则 x86_64 模拟器会出现“进程前台但 Flutter 首帧白屏”。

## 2026-07-17 可复现构建记录

- OpenHarmony Flutter：3.41.10-0.0.pre-7307，Dart 3.11.5。
- HarmonyOS SDK：API 24；ohpm 6.1.2.285；Node 18.20.1；hvigorw 可用。
- 连接设备：DevEco Pura 90 模拟器，`127.0.0.1:5555`，`x86_64`，API 24。
- 定向静态分析：平台抽象、认证、教务和通知相关文件 0 问题。
- 定向测试：既有认证、教务、平台边界、私信通知、考试缓存和竞赛导入 71 项通过；新增卡片、实况窗、应用接续、Scan Kit 和平台服务测试 26 项通过。
- 认证修复：普通 API 401 会等待本地完整会话清理完成；并发清理复用同一任务；`/edu/*` 401 只使教务会话失效，不清除 App 登录。
- 教务绑定修复：学号规范化、空凭据前置校验、单条原子缓存和安全存储失败回滚已覆盖；绑定失败时弹窗保留，可直接修改后重试。
- Android 回归构建：标准依赖恢复官方 JPush 3.4.6 后重新生成 `app-debug.apk`，230,069,846 bytes；SHA-256 为 `4229B43A046AB918BB64945391B529338DD0B41E0AA312AE94F7D6C7D30965D6`。
- 构建命令：`tool/build_harmony.ps1 -Mode debug -TargetPlatform ohos-arm64 -SkipTests`。
- 产物：`client/build/ohos/hap/entry-default-signed.hap`，217,339,154 bytes。
- SHA-256：`82C7FB766CD14EEFB562FE5485AE9A7F445D9EC3EC1A9C40A3488C7E4D67DD43`。
- 包内架构：`libs/arm64-v8a/libflutter.so` 已确认存在。
- x64 构建命令：`tool/build_harmony.ps1 -Mode debug -TargetPlatform ohos-x64 -SkipTests`。
- x64 产物：`client/build/ohos/hap/entry-default-signed.hap`，217,017,635 bytes。
- x64 SHA-256：`51B24571C22A6856195C4689DC3FD69370E046859E6EB91E04CE1CDD4A62A09B`。
- 已补齐 `plugins.flutter.io/shared_preferences` 原生通道；启动、教务页和进程重启日志均未再出现该通道的 `MissingPluginException`。
- 已补齐 `shenliyuan/deeplink` 原生通道：`sylulive://grades` 冷启动进入成绩页、`campus://timetable` 热启动触发 `onNewWant` 并切换课表，消费后普通重启不重放；非法 host 无法隐式拉起应用。
- 推送和私信本地通知已通过 `sylulive_push_bridge` 双实现完成编译期隔离；`main.dart` 与平台聚合层不再引用 Android 通知实现，OHOS 应用协调器不加载 Android 通知插件类型。
- OHOS 的 Pub 图、自动注册器、OHPM 锁文件和最终 HAP 内部清单均无 `jpush_flutter`、`@jg/push`、`jg_md5_push` 和注入权限；构建脚本已增加入口边界强制扫描。
- 最新 HAP 已在不卸载、不清数据的前提下覆盖安装并启动；`EntryAbility` 与应用进程均为前台，启动日志无 `MissingPluginException`、Dart 未处理异常、Fatal 或 AppFreeze。
- 运行验证：首帧、首页真实数据、App 登录恢复、教务绑定信息恢复均通过；点击课表直接进入第 20 周页面，`/api/edu/status` 返回 200 且包含绑定状态和学生信息字段。
- 课表交互验证：从第 20 周横向切换到第 16 周后，真实课程卡片正常渲染；“体育4”详情正确显示教师李钰涛、文体中心 B 馆篮球馆、周一第 1-2 节和第 2-17 周。
- 缓存验证：强停应用进程后重新启动，不清数据进入课表，再切换到第 16 周，课程卡片完整恢复。
- 日志中有 14 条图片方向元数据 401 警告，随后图片均正常解码，未影响页面功能。
- 截图证据：`sylulive-edu-shared-prefs-fixed.jpeg`、`sylulive-course-after-shared-prefs-fix.jpeg`、`sylulive-edu-bound-after-shared-prefs-restart.jpeg`、`sylulive-deeplink-cold.jpeg`、`sylulive-deeplink-hot.jpeg`、`sylulive-deeplink-consumed.jpeg`、`sylulive-stage5.jpeg`、`sylulive-stage5-course.jpeg`、`sylulive-week16.jpeg`、`sylulive-course-detail.jpeg`、`sylulive-course-cache-week16.jpeg`。
- 阶段 7 成绩验证：成绩接口返回 200，学期汇总、13 门课程、GPA、未通过和学位课状态正常；成绩详情中的成绩构成、学分、绩点和考试性质正常。
- 阶段 7 竞赛验证：分类、总览、列表和用户状态接口均返回 200，页面筛选正常；当前服务端推荐、学校认定等筛选均为 0 条，因此详情和加入计划同步仍待真实数据。
- 阶段 7 平台降级：考试页在 OHOS 隐藏未接入的桌面小组件、文件导入导出和系统日历入口；竞赛 JSON 导入改为文本粘贴后调用既有 preview API，并在本地拒绝空值、非法结构和超过 2 MB 的内容。新预览失败时旧 payload 会立即清除，避免误提交。
- 阶段 7 截图证据：`sylulive-stage7-grades-settled.jpeg`、`sylulive-stage7-grade-detail.jpeg`、`sylulive-stage7-competition.jpeg`、`sylulive-stage7-competition-recognized.jpeg`。
- 阶段 7 最新 x64 HAP：`entry-default-signed.hap`，217,013,536 bytes，SHA-256 为 `3773DE9B4B5F6B9859AA974BF4CCE09EA998D1F31BD7619689B0B575A5D51037`；已使用 `hdc install -r` 保留数据覆盖安装，首次安装时间保持 `1784194602353`，更新时间为 `1784268781951`，登录态与教务绑定均保留。
- 阶段 7 考试页设备验收：OHOS 顶栏只保留返回、学期选择与手工添加；小组件、文件导入导出、系统日历入口均隐藏。当前学期 `2025-2026-02` 为正常空状态；只检查手工添加表单后取消，没有新增或保存考试数据。
- 阶段 7 竞赛 JSON 设备验收：非法 `not_json` 在本地提示格式错误；合法 `{"events":[]}` 调用 preview API 返回 200，页面显示 0 个比赛预览。未点击“合并”或“覆盖”，没有修改计划数据；日志无 `MissingPluginException`、未处理异常、Fatal 或 AppFreeze。
- 阶段 7 新截图证据：`sylulive-exam-page-live.jpeg`、`sylulive-exam-add-live.jpeg`、`sylulive-exam-manual-live.jpeg`、`sylulive-import-json-live.jpeg`、`sylulive-import-invalid-live.jpeg`、`sylulive-import-valid-preview2-live.jpeg`。
- 阶段 8 卡片实现：已接入 Flutter HomeCardService、ArkTS MethodChannel、Preferences、FormExtensionAbility，以及 2x2 下一节课、4x2 今日课程和 4x2 学业提醒三张服务卡片；课程、考试、竞赛刷新入口均已接入。
- 阶段 8 实机首轮反馈：三张卡片均可添加并显示空状态；考试页手动添加点击“添加”无响应；桌面处于卡片编辑模式时点击卡片未拉起应用。
- 阶段 8 考试修复：无本地考试时仓库不再返回不可修改的常量列表；弹窗控制器改由路由内 `StatefulWidget` 在真正卸载时释放，避免退场动画期间 `TextEditingController was used after being disposed`。手动添加、关闭弹窗、页面展示和 SharedPreferences 持久化组件测试通过，测试使用内存存储，未写入设备考试数据。
- 阶段 8 卡片跳转修复：三张动态卡片依据华为官方指南改为根容器 `onClick + postCardAction({ action: 'router', abilityName: 'EntryAbility', params: { homeCardRoute } })`；`OhosDeepLinkPlugin` 同时兼容直接参数和 `parameters.params` 包装。需退出桌面编辑模式后复验实际跳转。
- 阶段 8 本轮定向测试：考试手动添加持久化和三张动态卡片 router 结构共 6 项通过；API 24 HAP 编译和签名通过。
- 阶段 8 最新 x64 HAP：`entry-default-signed.hap`，217,246,224 bytes，SHA-256 为 `4C968427902608A262A83A58CA05A18800DD07D2E70198ED05BBCB6EEA5576E8`；上一版本已使用 `hdc install -r` 覆盖安装并保持首次安装时间 `1784194602353`，本次参数兼容性版本等待模拟器恢复连接后部署。
- 阶段 9 Flutter 状态机：课表同步会选择正在进行或 60 分钟内开始的下一节课；超过窗口不创建，到达开始时间更新，到达结束时间结束。平台服务改为按平台复用，避免生产环境每次同步丢失去重状态。
- 阶段 9 ArkTS 桥接：`OhosLiveViewPlugin` 使用 `isLiveViewEnabled`、`startLiveView`、`updateLiveView`、`stopLiveView` 和 `getActiveLiveView`；活动载荷写入 ArkData Preferences，进程重启后可恢复稳定 ID 和 sequence，退出账号可枚举并清理。
- 阶段 9 跳转与回归：WantAgent 点击参数复用 `homeCardRoute` 深链协议进入课表；阶段 9 状态机及认证、卡片相关 5 个测试文件共 55 项通过，定向静态检查无告警。
- 阶段 9 最新 x64 HAP：已合并阶段 10–12 代码后重新生成 `entry-default-signed.hap`，SHA-256 为 `9CECB8F6BE5B745ED36A637B12F45749AFBEB44EFFA9C90E5E82C60A9580D4E2`；API 24/Hvigor 编译、签名、`hdc install -r` 覆盖安装和启动均通过。
- 阶段 10 Scan Kit：`OhosScanPlugin` 已接入 API 24 默认扫码界面；Flutter 严格解析 `sylulive://competition/<id>` 和 `sylulive://schedule/share/<code>`，竞赛码先预览确认；解析、取消和错误映射定向测试共 12 项通过。入口暂不开放，等待用户在设备上验收扫码权限、取消、错误码和详情跳转；课表分享码导入因仓库缺少后端 API 保持阻断。
- 阶段 11 应用接续：`ContinuationStore`、`OhosContinuationPlugin` 和 `EntryAbility.onContinue` 已完成；仅保存竞赛详情 ID、路由和可选草稿，不保存 Token 或教务密码；Flutter/ArkTS 构建和模拟器启动日志验证通过。跨设备接续仍需第二台 HarmonyOS 设备。
- 阶段 12 自适应：鸿蒙模块声明覆盖 `phone`、`tablet`、`2in1`；竞赛中心在 840dp 以上切换列表加详情双栏，窄屏使用单列，Flutter 分析通过。实体平板/2in1 的横竖屏和触控验收待补。
- 当前限制：因没有可恢复的账号凭据，为保留现有登录和教务绑定状态，本轮未执行手动退出、解绑或重新绑定；阶段 5、6 继续保持进行中。阶段 7 保持进行中，仅剩无真实竞赛数据导致的详情和加入计划设备验收。阶段 8、9 代码已部署，等待用户完成交互验收。阶段 10 入口和课表分享码导入仍受设备/后端条件限制。
