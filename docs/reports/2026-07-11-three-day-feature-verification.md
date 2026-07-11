# 近三天新功能全面验证与修复报告

## 1. 验证范围

- 验证日期：2026-07-11
- 时间窗口：2026-07-08 16:37 至 2026-07-11
- 对比基线：`07b509b5aa0b4389ec46c8e61c8acfe0aab59c20`
- 验证基线：`origin/fwqtest` 的 `13d4bd97641098ae5ec0d166fe879e0744619ee5`
- 修复分支：`codex/verify-new-features-20260711`
- 变更规模：98 个提交，351 个文件，36,487 行新增，8,126 行删除

本次以最新远端基线的当前行为为准，覆盖 `client`、`server`、`python-edu-service` 三个主模块。原工作目录中已存在的教务登录错误分类改动未带入本分支。

## 2. 总体结论

近三天新增功能的主体代码、路由、数据模型和现有自动化测试基本完整。验证中发现并修复 3 组 P0 问题：校历可能倒退到旧学年、服务端可能返回错误的“当前校历”与错误版本号、Android 插件 JVM 目标不一致导致 APK 无法构建。

修复后，Go、Python、Flutter 全量测试通过，Android 调试包构建成功，并已在 Android 模拟器上完成覆盖安装和冷启动，未出现 Flutter/Android 崩溃日志。

## 3. 新功能完整性检查

| 功能域 | 验证内容 | 结果 |
| --- | --- | --- |
| 结构化校历 | 服务端导入/发布/查询、客户端内置回退、缓存和远程替换、学年与版本比较 | 发现缺陷后已修复，回归通过 |
| 独立组队大厅 | 创建、公开列表、详情权限、申请、队长通过、满员状态 | 新增 Handler 真实请求级生命周期测试，连续 3 轮通过 |
| 试卷库 | 模型、分页、上传/预览/下载、审核、私有文件路径与部署资产 | Go/Flutter 定向与全量测试通过 |
| 首页混合信息流 V2 | 活跃度、新鲜度、候选回退、深页追加、缓存版本与会话恢复 | 排序与客户端隔离测试通过；当前实现是混合热度排序，不将其误报为个性化推荐 |
| 竞赛中心 | 分类、受众匹配、批量状态机、JSON 预览/入库、学生端卡片 | Go/Python/Flutter 相关测试通过 |
| 课表与教务会话 | 周滑动、学期起始日选择、缓存、会话锁、结构化过期错误 | Flutter/Python/Go 全量测试通过 |
| Android 课表/考试小组件 | 插件编译、Android 资源、整包构建、模拟器冷启动 | 发现 JVM 目标冲突后已修复，构建和启动通过 |
| 试卷库/网站大全等工具箱入口 | 入口组件、导航和基础页面渲染 | Flutter 组件测试通过 |

## 4. 缺陷与修复清单

### P0-1 旧学年校历可覆盖新学年

- 症状：学年不同时 `shouldReplaceCalendar` 无条件返回 `true`；无缓存时又绕过比较逻辑。
- 影响：2025—2026 远程数据可覆盖 2026—2027 内置校历。
- 修复：按学年起始年、schema 版本、内容版本、revision 顺序比较；无缓存场景也必须执行同一替换判定。
- 防回归：新增旧学年不替换、无缓存时保留内置新学年两个用例。

### P0-2 服务端“当前校历”与响应版本可错误

- 症状：`GetCurrent` 只按 `published_at` 选择；响应内层 JSON 保留导入文件的旧 `version`。
- 影响：后发布的旧学年可被当作当前学年；客户端看不到数据库中的真实版本。
- 修复：按 `academic_year DESC, version DESC, published_at DESC, id DESC` 选择；响应时用数据库的学年、版本和状态覆盖内层 JSON。
- 防回归：新增跨学年选择和数据库版本回填用例。

### P0-3 Android APK 因插件 JVM 目标不一致无法构建

- 症状：`photo_manager` 出现 Java 17/Kotlin 21，`add_2_calendar` 出现 Java 1.8/Kotlin 17。
- 根因：Flutter 插件的 Java 目标不同，Kotlin 默认目标又受当前 JDK 21 影响。
- 修复：Android 库子项目求值完成后，将它的 Kotlin JVM 目标对齐该插件已声明的 Java 目标。
- 防回归：两个原失败插件任务和完整 `assembleDebug` 均已通过。

## 5. 验证结果

- `go test ./...`：通过
- `go vet ./...`：通过
- `go build ./...`：通过
- 近三天功能 Go Handler/Service 定向用例 `-count=3`：通过
- `python -m pytest -q`：164 passed，1 条 Pydantic 弃用警告
- `python -m compileall -q .`：通过
- `flutter test --reporter compact`：358 passed
- `flutter analyze --no-fatal-infos --no-fatal-warnings`：命令通过，仍有 440 条历史 warning/info
- `:photo_manager:compileDebugKotlin`：通过
- `:add_2_calendar:compileDebugKotlin`：通过
- `flutter build apk --debug`：通过
- Android 模拟器覆盖安装：成功
- Android 模拟器冷启动：`Status: ok`，进程存活，无 `FATAL EXCEPTION`/`E/flutter`

APK 产物：

- 路径：`client/build/app/outputs/flutter-apk/app-debug.apk`
- 大小：193,784,472 bytes
- SHA256：`91FED2E552BEEFE5E9845E3781AEC1DF5B0DB14B7975D8C7D1BDB5E4908ED9B2`

## 6. 未宣称完成的外部验证

以下项目需要真实环境或生产数据，本次不伪装为已验证：

- 真实 PostgreSQL 部署下的数据迁移和高并发压测。
- 真实学校教务系统登录、课表/成绩抓取及上游页面漂移。
- 生产环境的试卷私有存储、Nginx 反向代理和大文件上传。
- 真实用户数据下的首页长时间排序效果与个性化效果；当前代码本身未实现用户偏好建模。

## 7. 后续清单

- P1：在 CI 中固定执行 `flutter build apk --debug`，把插件 JVM 目标冲突作为发布阻断项。
- P1：增加 PostgreSQL 集成环境，覆盖组队并发审核、试卷审批和首页会话竞争。
- P2：分模块清理 440 条 Flutter 分析提示，不与本次 P0 修复混合。
- P2：将 Pydantic `Field(example=...)` 迁移为 `json_schema_extra`，消除 Pydantic 3 升级前的弃用警告。
