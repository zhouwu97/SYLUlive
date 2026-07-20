# 客户端课表和成绩保险箱阶段 4B

## 阶段边界

本阶段将既有课表和成绩数据接入账号隔离的 AES-256-GCM 个人数据保险箱，并把
课表、成绩的最小化只读概览接入 `PersonalDataGateway`。

本阶段不包含：

- Personal Skill、Tool Calling、权限预览或任何模型个人数据发送；
- GPA、学分、毕业判断、竞赛匹配或运动建议等确定性计算；
- 课表或成绩的新产品页面、自动联网刷新或后台抓取；
- 课表考试安排、成绩详情导出或写操作；
- Gateway 之外的 Vault 读取入口。

自定义模型和校园公益模型在本阶段都不会收到课表、成绩、来源账号或保险箱
Payload。

## 现状审计与迁移

原课表缓存使用 `SharedPreferences`：课程、隐藏课程、学期起始日期和存档分别
落在多个明文键中。虽然其中多数键包含 App 用户 ID，但没有来源账号指纹；存档
课程数据键甚至不包含 App 用户 ID。因此它们无法被安全地归属到当前教务账号。

阶段 4B 不猜测这些数据的归属。首次获得同时有效的 App 用户和教务来源账号时，
`ScheduleCacheStore` 会：

```text
识别旧明文键
-> 删除无法验证归属的数据
-> 设置 schedule/<app-user-hash>/needs_resync/v1
-> 等待用户重新同步
```

旧数据不会被迁入新来源账号，也不会被作为 Gateway 或页面缓存的后备来源。全局
存档数据键也一并删除，以避免其他账号的未归属明文继续留在设备上。

成绩此前只保存在 `EduProvider` 内存中；没有可安全迁移的持久化成绩缓存。新的
网络成功结果直接写入保险箱。教务接口返回 `success: false` 时不会覆盖已有加密
快照或创建新的学业情况记录。

## 加密模型

课表和成绩分别使用既有的个人数据类型：

```text
personal_vault/<app-user-hash>/schedule.bin
personal_vault/<app-user-hash>/academic.bin
```

两类快照均由 `AccountScopedSnapshotStore` 处理。它使用每个 App 用户独立的数据
密钥、设备盐参与的来源账号指纹、AES-256-GCM、12-byte nonce 和 128-bit 认证标记。
读取时必须同时通过账户、数据类型、AAD、来源账号、内容哈希和 SchemaVersion
校验；未知 SchemaVersion、密文篡改、密钥缺失或 Payload 格式错误均失败关闭。

课表将所有学期聚合为一个 `schedule` 快照。每个学期保留课程、隐藏课程 ID、学期
起始日期及用户存档；同一 App 用户的读改写经共享串行队列执行，避免多个学期互相
覆盖。成绩把各学期的原始网络记录和已验证的学业情况聚合为 `academic` 快照，并以
同样方式串行化。

## 运行时数据流

```text
当前 App 用户 + 已绑定教务来源账号
                 |
                 v
CourseScheduleProvider / EduProvider
                 |
                 +-- 通过教务代理按需获取本次课表、成绩
                 +-- 网络成功后确认上下文未变化
                 |
                 v
ScheduleCacheStore / AcademicCacheStore
                 |
                 v
AccountScopedSnapshotStore (AES-256-GCM)
                 |
                 v
PersonalDataGateway
       |                         |
       v                         v
ScheduleOverview          AcademicOverview
```

课表 Provider 的异步操作固定发起时的 App 用户、来源账号、学期和 Store 实例。用户
换号、来源账号变化或学期切换后，延迟网络结果不会写入新上下文，也不会恢复旧页面。
`EduProvider` 对课表、成绩和学业情况请求同样在响应前后核验账号上下文。

教务代理仅处理本次按需请求。客户端不会读取 `/edu/courses/local`，也不会调用
`/edu/courses/sync` 将原始课程、教师或地点回传为校园服务器持久化副本；成功响应只会
写入当前 App 用户和来源账号绑定的本地 AES-GCM Vault。

课表和成绩链路的调试日志只记录请求路径、状态码、异常类型、学期和数量；不会记录
响应正文、课程名称、成绩、来源账号、密码、Cookie 或 Token。

## Gateway 输出边界

`getScheduleOverview(start, end)` 只允许最多 31 个自然日的范围，返回该范围内的
课程出现项、教学时间、教师和地点。它不返回课程内部 ID、颜色、备注、存档 Payload
或来源账号。

`getAcademicOverview()` 只返回学期覆盖、每学期课程数量、总记录数量和是否存在学业
情况。它不返回单门成绩、课程名称、学号、GPA、学分、毕业结论或 Vault Payload。

两类 Gateway 读取均不联网；数据缺失、过期、来源不匹配、未知版本、密文损坏和
账号关闭分别返回结构化状态，不回退到明文缓存或其他账号数据。

## 威胁模型

- App 账号切换：账户哈希、Provider 会话 generation 和 Gateway 上下文共同限制读取。
- 同一 App 用户更换教务账号：来源账号指纹不匹配时旧快照不可读。
- 延迟请求：课表和教务请求在每个关键异步边界检查发起上下文，旧响应不写入新账号。
- 旧明文缓存：无法证明来源归属时只删除并要求重新同步，不进行猜测性迁移。
- 伪造或篡改快照：AES-GCM、内容哈希、数据类型和 SchemaVersion 检查失败后不返回
  部分对象。
- 后续模型越权：本阶段没有模型调用、Skill 注册或个人数据外发路径；后续阶段必须经
  固定 Skill、权限预览和最小化结果协议接入。

## 验证

```powershell
cd client

dart format `
  lib/features/campus_data/storage/schedule_cache_store.dart `
  lib/features/campus_data/storage/academic_cache_store.dart `
  lib/features/ai_runtime/personal_data/adapters/schedule_gateway_adapter.dart `
  lib/features/ai_runtime/personal_data/adapters/academic_gateway_adapter.dart `
  lib/features/ai_runtime/personal_data/models/schedule_overview.dart `
  lib/features/ai_runtime/personal_data/models/academic_overview.dart `
  lib/providers/course_schedule_provider.dart `
  lib/providers/edu_provider.dart `
  lib/screens/course_schedule_screen.dart `
  lib/screens/edu_screen.dart `
  test/features/campus_data/storage/schedule_academic_cache_store_test.dart `
  test/features/ai_runtime/personal_data/gateway/personal_data_gateway_test.dart `
  test/course_schedule_provider_cache_test.dart `
  test/providers/edu_provider_test.dart

flutter analyze --no-fatal-warnings --no-fatal-infos `
  lib/features/campus_data/storage `
  lib/features/ai_runtime/personal_data `
  lib/providers/course_schedule_provider.dart `
  lib/providers/edu_provider.dart `
  lib/main.dart `
  test/features/campus_data/storage/schedule_academic_cache_store_test.dart `
  test/features/ai_runtime/personal_data/gateway/personal_data_gateway_test.dart `
  test/course_schedule_provider_cache_test.dart `
  test/providers/edu_provider_test.dart

flutter test --no-pub
git diff --check
```

回归测试覆盖：App 用户与来源账号隔离、多学期并发写入、旧明文清理及重新同步、密文
无明文课程字段、未知 SchemaVersion、Gateway 最小化输出、延迟课表响应换号、成绩
写入失败关闭和失败学业情况不落盘。

### 本地验证记录（2026-07-20）

- `flutter test --no-pub`：602 项通过；
- `flutter analyze --no-fatal-warnings --no-fatal-infos`：退出码 0、无 error。仓库仍有
  399 条既有 warning/info，阶段 4B 文件未新增静态错误；
- `git diff --check`：通过；
- 已扫描正式 `lib` 代码：不存在 `/edu/courses/local`、`/edu/courses/sync` 或
  `syncCourses` 调用；课表、成绩链路日志不输出响应正文、请求正文、认证头、密码、
  Cookie、Token、学号、课程名或成绩。

这些是本地验证记录，不替代后续阶段 4B PR 上由 GitHub Actions 执行的独立 CI。
