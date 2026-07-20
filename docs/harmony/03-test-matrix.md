# 鸿蒙迁移测试矩阵

| 范围 | 检查项 | 当前状态 |
| --- | --- | --- |
| Android | `flutter pub get`、全量测试、Debug APK | 基线已记录；全量测试有 1 个迁移前 TLS 断言失败 |
| Ohos 环境 | `flutter doctor -v`、`ohpm --version`、`hvigorw --version`、`hdc list targets` | 当前终端待配置 SDK、ohpm、hvigorw |
| Ohos 构建 | `flutter build hap --debug --dart-define=APP_PLATFORM=ohos` | 已有历史成功 HAP；待环境脚本验证可复现 |
| 核心业务 | 首装、冷启动、登录、Token 恢复、退出、课表、学期/周次切换 | 待真机 |
| 竞赛闭环 | 推荐、详情、加入计划、计划同步 | 待真机 |
| 鸿蒙能力 | 卡片、实况窗、扫码权限、错误码、退出清理 | 待原生桥接 |
| 自适应 | 手机、平板横竖屏、宽屏双栏 | 待 UI 阶段 |
| Android 回归 | 极光、通知、小组件、课程提醒、APK 更新、保活 | 每次平台服务变更后回归 |
# 鸿蒙验证矩阵

## 构建目标

- DevEco Pura 90 模拟器为 `x86_64`，使用 `ohos-x64`：
  `./tool/build_harmony.ps1 -Mode debug -TargetPlatform ohos-x64 -SkipTests`
- 实体 HarmonyOS NEXT 设备通常为 `arm64-v8a`，使用默认 `ohos-arm64`。
- 安装前用 `hdc shell param get const.product.cpu.abilist` 确认 ABI；若 HAP 的 `libs/` 目录架构与设备不一致，系统会拒绝安装。
- 构建脚本会在 ArkTS 编译前修正 Flutter 嵌入层的 ICU 原生库目录；否则 x86_64 模拟器会出现“进程前台但 Flutter 首帧白屏”。
