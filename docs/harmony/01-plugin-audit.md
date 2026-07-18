# 鸿蒙插件兼容性审计

状态说明：本清单先区分“已随当前 HAP 编译进入工程”“纯 Dart 或跨平台候选”“需要真机最小验证”和“Android 专属”。HAP 编译通过不等同于 API 已在真机可用。

## 已在当前 ohos 脚手架中注册

| 插件 | 当前锁定版本 | 结论 | 后续动作 |
| --- | ---: | --- | --- |
| `photo_manager` | 3.9.0 | 当前 Ohos 构建已注册 | 仅保留图片选择最小真机验证，复杂相册能力首版隐藏 |

## 需优先真机验证的跨平台插件

| 插件 | 当前锁定版本 | 风险 | 首版策略 |
| --- | ---: | --- | --- |
| `shared_preferences` | 2.2.2 | 登录恢复与缓存依赖 | 验证 Ohos 实现；不可用时仅迁移非敏感缓存 |
| `flutter_secure_storage` | 9.2.4 | 教务密码、Token 安全存储 | 必须使用 Ohos 安全存储桥接；禁止降级为 Preferences |
| `path_provider` / `file_picker` | 2.1.5 / 8.3.7 | 文件目录和选取接口差异 | 首版只保留业务所需的选取入口 |
| `cached_network_image` / `flutter_cache_manager` | 3.3.1 / 3.4.1 | 缓存后端差异 | 网络图片失败必须降级为占位图 |
| `hive` / `hive_flutter` / `sqflite` | 2.2.3 / 1.1.0 / 2.3.2 | 本地数据库实现 | 先验证课程缓存与帖子缓存初始化 |
| `url_launcher` / `package_info_plus` | 6.2.4 / 8.0.0 | 市场跳转、版本检查 | Ohos 端只允许市场或分发页跳转 |
| `webview_flutter` / `flutter_inappwebview` | 4.13.0 / 6.1.5 | WebView 原生实现 | 不属于登录课表首链路；首版可关闭 |
| `image_picker` / `image_cropper` / `gal` | 1.0.7 / 8.0.2 / 2.3.2 | 相册与裁剪 | 首版隐藏复杂上传 |
| `flutter_local_notifications` / `add_2_calendar` | 17.2.4 / 3.0.1 | 通知和日历接口 | Android 保留；Ohos 用原生能力替代 |
| `pdfrx` / `share_plus` | 2.4.7 / 10.1.4 | PDF 与分享原生能力 | 首版不作为必测能力 |

## Android 专属或必须隔离的能力

- `jpush_flutter` 私信通知与 Alias 状态机。主工程依赖中性
  `sylulive_push_bridge` 门面：标准依赖指向 Android 转发实现，继续使用官方
  `jpush_flutter` 3.4.6，并封装私信本地通知和原生通道；OHOS 依赖模板覆盖为
  无原生平台声明的空实现。`main.dart` 只依赖中性 `NotificationService`。
- OHOS 验收必须同时确认 `.flutter-plugins-dependencies`、自动插件注册器、
  OHPM 锁文件和最终 HAP 均不含 `jpush_flutter`、`@jg/push`、
  `jg_md5_push` 或 JPush 注入权限，不能只依赖运行时能力开关。
- Android `MainActivity` 的 APK 安装、课程提醒、小组件、前台保活和通知渠道。
- `HomeWidgetService`、`CourseReminderService`、`KeepAliveService` 中的 Android MethodChannel。
- APK 自更新：Ohos 仅执行版本检查与应用市场/官方分发页跳转。

## 依赖切换规则

标准环境始终以 `pubspec.yaml` 和 pub.dev 锁定版本为准。鸿蒙兼容 fork 只能由 `tool/use_ohos_deps.ps1` 写入临时 `pubspec_overrides.yaml`；恢复 Android/Web 时必须由 `tool/use_standard_deps.ps1` 删除该覆盖文件，并重新执行 `flutter pub get`。
