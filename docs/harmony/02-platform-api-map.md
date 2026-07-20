# 平台 API 边界

| 业务能力 | Flutter 统一接口 | Android 实现 | OpenHarmony 首版实现 | 失败降级 |
| --- | --- | --- | --- | --- |
| 平台识别 | `AppPlatform` | `android` | `ohos`（由 `APP_PLATFORM` 注入） | `other` |
| 能力展示 | `PlatformCapabilities` | 保持原有能力 | 未接入前隐藏入口 | 不影响页面主体 |
| 启动后初始化 | `PlatformBootstrap` | 课程提醒、私信本地通知 | 不初始化 Android 服务 | 记录日志 |
| 登录凭据 | `AuthCredentialStore` | `flutter_secure_storage` | Ohos 安全存储桥接 | 不允许明文 Preferences |
| 应用更新 | `AppUpdateService` | 下载 APK 并安装 | 打开市场/分发页 | 展示版本提示 |
| 课程卡片 | `HomeCardService` | 现有 `HomeWidgetService` | ArkTS 卡片桥接（后续） | 不显示设置入口 |
| 课程提醒/保活 | `ReminderService` | 现有 Android 服务 | 首版关闭 | 不阻断课表 |
| 深链/扫码 | `AppDeepLinkTarget` | 现有 MethodChannel | Scan Kit 返回文本后统一解析 | 提示无效二维码 |
