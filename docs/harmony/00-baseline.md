# 鸿蒙迁移基线

记录时间：2026-07-16；分支：`feature/harmony-flutter`；基线提交：`2f1b3f4`。

## 标准 Flutter / Android

- Flutter：3.41.8 stable（Framework `02085feb3f`）
- Dart：3.11.5
- `flutter pub get`：通过。
- `flutter analyze --no-fatal-warnings`：399 项既有问题。全仓静态检查仅用于记录基线；迁移改动采用文件级分析和目标测试作为门禁。
- `flutter test --reporter compact`：513 项中 512 项通过、1 项失败。
- 唯一失败：`test/security_regression_test.dart` 的 WebVPN TLS 回归断言。Python 教务服务源码仍包含 `badCertificateCallback` 文本；这是迁移前既有安全问题，不在本次鸿蒙平台改造中顺带修复。
- `flutter build apk --debug --dart-define=APP_PLATFORM=android`：通过。产物为 `client/build/app/outputs/flutter-apk/app-debug.apk`，生成时间 2026-07-16 17:53:09（+08:00），大小 193,979,947 bytes。

## OpenHarmony Flutter

- 独立 SDK：`D:\kaifa\Flutter-OHOS\flutter`
- Flutter：3.41.10-0.0.pre-7307（Framework `aa33b6e2a6`，Dart 3.11.5）。
- 已生成 `client/ohos/`，并保留在未提交工作区，避免覆盖当前脚手架。
- 已存在签名 HAP：`client/ohos/entry/build/default/outputs/default/entry-default-signed.hap`，生成时间 2026-07-16 17:36:38（+08:00），大小 251,401,936 bytes。hvigor 构建日志显示 `PackageHap` 和 `SignHap` 完成。
- 当前终端尚未配置 HarmonyOS SDK、ohpm、hvigorw；OpenHarmony `flutter doctor -v` 因此报出这三项缺失。脚本会在构建前显式校验，不能把缓存产物当成当前环境可复现构建。

## 当前工作区说明

开始迁移前已有 `client/.metadata`、`client/lib/main.dart`、应用更新服务和 `client/test/widget_test.dart` 的本地修改，以及未跟踪的 `client/ohos/`。这些内容均视为既有改动，不由本迁移任务重置或覆盖。
