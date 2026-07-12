# CI 失败修复设计

## 背景

当前 CI 包含 Go 服务端、Python 教务服务和 Flutter 客户端三个任务。Python 任务已通过；Go 任务因仓库中的 Go 文件未统一执行 `gofmt` 而失败；Flutter 任务因把 `stable` 作为具体版本号传给 `subosito/flutter-action` 而无法安装 SDK。

## 修复范围

1. 将 Flutter CI 版本固定为 `3.44.4`，避免把渠道名误当成版本号，同时保证构建环境可复现。
2. 对 `server` 目录下全部 Go 源文件执行官方 `gofmt`，继续保留现有严格格式检查。
3. 不修改业务逻辑、测试断言和 CI 触发条件。

## 验证标准

1. `gofmt -l .` 在 `server` 目录下无输出。
2. `go test ./...` 通过。
3. Python 服务的 `compileall` 和 `pytest` 通过。
4. `flutter pub get` 与 `flutter test --reporter compact` 通过。
5. CI 工作流中 Flutter Action 使用可解析的固定版本，且工作区不存在空白错误。

## 风险与控制

Go 格式化会产生较多机械性差异，但不改变程序语义。验证时将检查差异类型，并运行完整服务端测试，避免格式化过程中混入业务改动。
