# 2026-10-23 单字符搜索补充修复

## 用户要求与结论

用户明确要求“不要拒绝”，即单独输入 `2` 也应执行搜索。最终实现已将统一搜索、校园资讯搜索和 Flutter 客户端调整为支持 **1 至 64 个 Unicode 字符**。此前报告中“单字符仍不支持”的结论已被本次修订替代。

工作区、基准提交、设备、原有修改和首次整体回归见[初轮报告](2026-10-23-search-emulator-regression.md)。本次仍只修改当前 `SYLUlive-zhzh` 仓库。维护者随后要求接入服务器并明确授权“推送”；下文区分已完成的本地验证与线上状态。

## Changed

- `server/internal/handlers/search.go`：帖子关键词、用户昵称、用户 ID 支持单字符，包括 `2`、汉字、字母、Emoji。
- `server/internal/handlers/campus_article_handler.go`：校园资讯按标题／正文搜索同步支持单字符；省略关键词仍返回普通列表。
- `client/lib/screens/search_results_screen.dart`：不再以“至少两个字符”阻止查询；单字符与其他合法关键词执行同一条真实搜索流程。
- 客户端回归新增单字符帖子和用户成功路径；服务端补充数字、单字汉字、大小写、Emoji、首尾空白及公开字段保护用例。
- `server/API.md` 更新当前输入契约；初轮报告保留历史结果并标明已被修订。

## Preserved

- 64 字符上限、空关键词提示、纯通配符处理、LIKE 转义、匿名请求频率限制、分页上限和公开用户字段边界。
- 前次已修复的错误语义、重试、分页失败恢复、账号会话隔离、过期请求取消与校园周次显示。
- 现有正常多字符查询及响应格式；无新增依赖、数据库迁移或生产配置修改。

## Tests

证据均位于本机忽略目录 `_codex_evidence/`，不提交 APK、运行日志和测试数据库。

| 检查 | 结果 | 证据 |
| --- | --- | --- |
| 修改前新增服务端正向用例 | 失败，旧实现对单字符返回 400 | `single-character-before-20261023.log` |
| 修改前新增客户端正向用例 | 4 项失败，旧实现未发送单字符请求 | `single-character-client-before-20261023.log` |
| `go test ./internal/handlers -run 'Test.*Search' -count=1` | 通过，覆盖新旧搜索及校园资讯用例 | `single-character-go-focused-20261023.log` |
| `flutter test test/screens/search_results_screen_test.dart --reporter expanded` | **26 项通过** | `single-character-client-focused-20261023.log` |
| 全量 `flutter test --reporter expanded` | **2492 项通过、6 项因私聊暂停而跳过、0 失败** | `single-character-client-all-20261023.log` |
| 修改的两个 Dart 文件静态分析 | **No issues found** | `single-character-analyze-20261023.log` |
| `go vet ./...`、`go build ./...` | 退出码 0 | `single-character-go-vet-20261023.log`、`single-character-go-build-20261023.log` |
| 本地 API 与默认 API 两份调试 APK 构建 | 均通过 | `single-character-build-local-20261023.log`、`single-character-build-default-20261023.log` |
| `git diff --check` | 通过 | 交付前执行 |

本轮 Go 全量测试的实际结果为 **failure**：`TestAdminUnpublishReturnsTransactionSnapshot` 和 `TestExamPaperUploadRateLimitsBurstSubmissions` 的业务步骤执行后，Windows 的 `t.TempDir` 清理报告目录非空。相关日志保留在 `single-character-go-all-20261023.log`。针对这两个用例的独立诊断均通过，见 `single-character-go-temp-cleanup-diagnostic-20261023.log`；未定位目录占用者，也未改动、删除断言或跳过这两个无关试卷测试，因此不把本次全量 Go 结果改写为通过。

单字符服务端用例同时验证匿名搜索第 31 次仍返回 429、`Retry-After` 为 60，64 个 Emoji 字符可正常请求，以及用户结果不暴露学号、密码哈希或邮箱字段。

## 模拟器实际链路

使用当前生产代码中的 `SearchHandler` 和 `CampusArticleHandler` 启动本地只读联调服务，数据来自独立内存 SQLite 的人工测试夹具，不连接生产数据库或外部服务。客户端使用正常 `lib/main.dart` 构建，通过编译参数指向该本地 API，以 ADB reverse 连接，未修改持久客户端配置。

| 前置条件 → 操作 | 预期 | 实际与证据 |
| --- | --- | --- |
| 游客、本地服务 → 首页输入 `2` | 执行搜索并显示匹配帖子 | 返回 **23 条结果**，首屏 20 条；`single-qa-posts-2.png/xml` |
| 保持 `2` → 切换用户 | 支持单数字 ID | 返回 **ID 2** 的公开用户；`single-qa-user-2.png/xml` |
| 切回帖子 → 连续向下滚动 | 正常加载第二页并终止分页 | 追加 3 条，底部显示“已显示全部结果”；`single-qa-pagination-end.png/xml` |
| 输入单字母 `Z` | 合法查询，无匹配时显示空结果 | “没有找到相关帖子”；`single-qa-empty-one-character.png/xml` |
| 将 `Z` 改回 `2` | 空状态能够恢复 | 重新返回 23 条；`single-qa-final-posts-2.png/xml` |
| 本地 HTTP `/api/campus/articles?q=2` | 校园资讯支持单字符 | 200，返回 1 条测试资讯 |

只有 ADB 设备输入和截图，没有桌面鼠标操作。界面中的“本地联调”“本地隔离测试数据”为刻意标识的人工夹具内容，不能作为线上数据量或线上已上线的证据。

## 构建与当前设备状态

- 本地联调完成后，已覆盖安装 **默认线上 API 调试版** `com.example.shenliyuan`，其 API 为 `https://sylulive.online/api`；已移除 `tcp:18080` 的 ADB reverse 映射并停止本地测试服务。全程通过 ADB，保留应用数据。
- 重新启动后，首页已恢复真实帖子，证据为 `online-restored-home.png/xml`。此前本地只读夹具仅提供搜索数据，其他列表为空，不能作为线上首页可用性的依据。
- 本地测试服务曾在 `server/` 运行 `go run ./scratch/single_character_qa`。该临时夹具目录属于忽略的本机证据，不纳入提交；内存数据随进程结束消失。
- 联调 APK：`_codex_evidence/single-character-local-qa-20261023.apk`。
- 联调 APK SHA-256：`6E2D72C136AC1FD0CC60E10A35BD0A26F795C8CC9A2DED53053F8FADABEA7194`。
- 默认 HTTPS API 调试 APK：`_codex_evidence/single-character-default-api-20261023.apk`。
- 默认 API APK SHA-256：`7D3E55BC816E74C96FC2F0BE5511B39DF106291EF8F631AA4024FC08F8BA761D`。

## 线上恢复与推送准备

- 单字符服务端修复提交：`244522e3`，仅包含两个处理器、对应测试及 API 契约。
- 推送目标为现有 `origin/xianzai`，官网与 Web 的既有未提交修改不纳入本次提交。
- 只读核验公网 `/api/version`：线上运行 `0d02aecc995a4f1305098116da420455841d7cc8`，构建时间为 `2026-10-15T02:59:15Z`。该版本包含当前本地分支尚未合入的登录安全修复；不可直接部署本地旧基线覆盖它。
- 已获取最新远程引用，正式服务端候选必须保留上述生产基线，并按 `DEPLOY.md` 固定完整 SHA、核验必要 CI 与安全扫描后执行正式入口。
- 当前机器只发现 GitHub SSH 配置，未发现主服务器的运维连接配置，已向维护者请求 SSH 入口。尚未执行服务器部署，不能将恢复线上 API 写成单字符功能已上线。

## Design QA

- **P0：0、P1：0**：本次单字符输入、正常结果、空结果、类型切换与跨页链路可完成。
- **P2：无新增**：前次记录的共享浮动底栏文字叠加仍保留。
- **P3：无新增视觉调整**：沿用现有布局、语义提示与错误恢复界面，未更新 Golden。

## Deferred 与上线边界

- 当前已实现并完成本地服务端、客户端和模拟器联调，并恢复模拟器线上接口；**线上服务端尚未部署**，线上旧的 2 字符规则需要服务端发布后才会改变。推送与发布实际结果以后续记录为准。
- 若回退单字符功能，需要同步回退服务端的两个输入校验和客户端校验，并重建客户端；回退会重新使单字符无法搜索。无数据库迁移需要回滚。
- 真实账号写入、学校个人数据、生产限流触发、独立 PostgreSQL 集成矩阵与前次列出的其他端／真机范围仍未实测。
- 保留本轮全量 Go 中两项临时目录清理失败及其诊断结果，后续仍需定位资源占用或运行环境的不稳定性。
