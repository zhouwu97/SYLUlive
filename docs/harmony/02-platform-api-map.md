# 平台 API 边界

| 业务能力 | Flutter 统一接口 | Android 实现 | OpenHarmony 首版实现 | 失败降级 |
| --- | --- | --- | --- | --- |
| 平台识别 | `AppPlatform` | `android` | `ohos`（由 `APP_PLATFORM` 注入） | `other` |
| 能力展示 | `PlatformCapabilities` | 保持原有能力 | 未接入前隐藏入口 | 不影响页面主体 |
| 启动后初始化 | `PlatformBootstrap` | 课程提醒、私信本地通知 | 不初始化 Android 服务 | 记录日志 |
| 登录凭据 | `AuthCredentialStore` | `flutter_secure_storage` | Ohos 安全存储桥接 | 不允许明文 Preferences |
| 应用更新 | `AppUpdateService` | 下载 APK 并安装 | 打开市场/分发页 | 展示版本提示 |
| 课表与考试卡片 | `HomeWidgetService` | RemoteViews | Form Kit 服务卡片，支持 2×2、2×4 | 桌面长按应用图标添加；设置页可手动同步 |
| 课程与日程提醒 | `ReminderNotificationClient` | 本地通知与 Android 提醒 | 系统代理提醒，按分类和业务 ID 更新或撤回 | 未授权或额度不足时反馈实际调度数量 |
| 私信推送 | `PushClient` | JPush | 用户主动开启后注册鸿蒙设备，使用 Registration ID 接收通知 | 注册失败在设置页显示，可重新登记 |
| 深链/扫码 | `AppDeepLinkTarget` | 现有 MethodChannel | Scan Kit 返回文本后统一解析 | 提示无效二维码 |
