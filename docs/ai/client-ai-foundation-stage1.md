# 客户端 AI Runtime 阶段 1

本阶段建立可替换的普通聊天模型运行时，范围仅限客户端模型接入，不读取、推断或上传成绩、体测、二课、课表或其他个人校园数据。

## 已实现范围

- `AIModelProvider` 统一模型能力探测与普通文本聊天接口。
- `CampusPublicProvider` 适配既有公益 AI 服务，只转发用户手动输入的文本。
- `OpenAICompatibleProvider` 使用 OpenAI 兼容的 `GET /models` 和 `POST /chat/completions`，固定 `stream: false` 和 `tools: []`，不注册 Tool Calling 参数。
- 非敏感 Provider 配置写入 `SharedPreferences`，键为 `ai_provider_config/<app-user-hash>/<provider-config-id>`；API Key 只写入 `FlutterSecureStorage` 的 `ai_provider_key/<app-user-hash>/<provider-config-id>`，不进入配置对象、JSON、日志或 UI 回显。当前 UI 使用 `default` 配置 ID。
- 未知、损坏或配置 ID 不匹配的 Provider 配置会失败关闭并提示重新配置，绝不回退为校园公益 AI。
- 删除配置时先清除该配置的 API Key，再删除普通配置；设置页会识别并提供清除“配置缺失但密钥仍存在”的残留密钥入口。阶段 1 不持久化能力探测结果或第三方聊天上下文，因此没有可遗留的对应缓存。
- 第三方服务端点必须是无账号、无查询参数、无 `.`/`..` 路径跳转的最终 HTTPS 地址。携带 API Key 的请求禁用自动重定向；Dio 只接受 2xx/3xx 以便任何 3xx 均被显式拒绝，浏览器端不启用第三方 Provider，避免浏览器自动重定向绕过该策略。
- `GET /models` 只用于测试连接和发现模型名称，聊天、流式和 Tool Calling 能力均标记为未知或关闭，不会因 HTTP 成功而被声明为可用。普通聊天固定 `stream: false`、`tools: []`，模型返回的工具 JSON 只会作为文本显示。
- 第三方请求使用 10 秒连接、15 秒发送和 60 秒接收超时；页面销毁、模型配置切换和账号上下文关闭都会取消当前请求。校园公益 AI 同时会以最多两秒的 best-effort 调用服务端 Run 取消接口。
- 普通聊天记录只保留在当前页面内存中，切换模型设置或账号上下文关闭后立即清空，不做本地持久化。上下文最多保留 20 条消息和 40000 个字符。校园公益 AI 与自定义模型分别持有服务端和本地上下文；自定义模型消息由客户端直接发送到用户配置的模型服务，不经过沈理校园服务器。

## 未实现范围

- 个人 Skill、成绩/体测/二课/课表读取。
- Tool Calling、函数参数、文件上传和本地个人数据保险箱。
- API Key 同步、导出或日志诊断。

## 平台与验证

- 校园公益 AI 保持既有认证客户端请求路径。
- 第三方 OpenAI 兼容服务只在非 Web Flutter 客户端启用，并依赖目标平台的 `FlutterSecureStorage` 实现；Web 端拒绝保存和发送第三方 API Key。
- 提交前已执行本次修改文件的 `flutter analyze`（0 问题）与 `flutter test --no-pub`（552 passed）；端点、账号隔离、空工具列表、SSE 完整性、退出超时、请求取消、密钥清理与失败关闭均有独立回归测试。

阶段 3 之前，账号缓存键继续使用 SHA-256 哈希化隔离；这不应被表述为匿名化或静态数据加密。
