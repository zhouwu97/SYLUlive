# 沈理校园客户端

这是 SYLUlive 的 Flutter 客户端，负责校园 App 的界面、账号交互、社区功能，以及逐步迁移到设备侧的个人教务访问。

## 客户端边界

- App 账号、社区、竞赛、通知和反馈通过 Go 服务端访问。
- 个人教务访问优先由客户端直接连接学校系统，并通过设备安全存储保存本地会话和缓存。
- 学校密码、Cookie、个人教务 HTML 和原始会话不得写入服务端日志、远程 AI、MCP 或普通业务接口。
- 迁移期旧 `/api/edu/*` 能力可能返回 `410`；客户端应遵循能力探测结果，不应反复调用已退役接口。

## 开发环境

- Flutter 3.x
- Dart（版本约束以 `pubspec.yaml` 为准）
- Android Studio 或 VS Code
- Android SDK；iOS 构建需要 macOS 与 Xcode

## 运行

```bash
flutter pub get
flutter run
```

本地联调时，请把客户端 API 地址指向开发机可访问的 Go 服务。不要把真实学校账号、密码或 Cookie 写入提交内容、测试快照和日志。

## 常用检查

```bash
flutter analyze
flutter test
```

涉及界面、动效和无障碍的改动，先阅读：

- [`../docs/design/DESIGN_SYSTEM.md`](../docs/design/DESIGN_SYSTEM.md)
- [`../docs/design/MOTION.md`](../docs/design/MOTION.md)
- [`../docs/design/ACCESSIBILITY.md`](../docs/design/ACCESSIBILITY.md)

## 目录概览

```text
lib/
├── core/       网络、配置、错误和基础能力
├── features/   账号、社区、教务、竞赛等产品模块
├── models/     数据模型
├── services/   App API、学校客户端和本地存储
└── theme/      设计 token、主题和动效
test/           单元、组件、集成和 golden 测试
```

完整的仓库文档入口见 [`../docs/README.md`](../docs/README.md)。
