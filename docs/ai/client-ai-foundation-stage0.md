# 客户端 AI 基础阶段 0 迁移说明

本文记录沈理校园客户端 AI 基础分支的阶段 0A/0B 基线与个人数据风险修复。

## 基线与分支

- `origin/main` 基线：`fb25561fb945603621a0be00bc5a92d26333d6d5`
- 原 `zhishiku` 保护分支：`backup/zhishiku-before-client-ai`
- 原 `zhishiku` 保护 SHA：`2541e39bc0ba4b5eaa4b8615df0f33388f05916f`
- 阶段 0B 提交：`1a8e9895e40c4e6f2451ca6969018524a114c7cf`
- 功能分支：`feature/client-ai-foundation`

阶段 0A 从最新 `origin/main` 建立独立 worktree，并只迁移公益 AI 所需的六个 AI 提交；投票、签到、表情等无关功能不在本分支范围内。

## 缓存命名空间

### 二课

旧固定键：

- `erke_scores_cache`
- `erke_summary_cache`
- `erke_snapshot`

新键：`erke/<sha256(app_user_id)>/snapshot/v2`

写入信封包含 `app_user_id`（App 用户 ID 的 SHA-256）、`source_account_fingerprint`（来源学号或来源账号的 SHA-256）、`schema_version: 2`、`fetched_at` 和 `payload`。

这些值是用于命名空间隔离的哈希化账号标识，并非匿名化或加密。学号和数字 ID 的取值空间有限，获得本地存储的攻击者理论上可以离线枚举；阶段 3 的保险箱应改用保存在安全存储中的安装密钥计算 HMAC-SHA256。

### 体测

旧键：`gym_cache_<studentId>_<year>`

新键：`physical/<sha256(app_user_id)>/<sha256(source_account_id)>/<year>`

信封包含 App 用户哈希、来源账号哈希、`schema_version: 2`、`fetched_at` 和 `data`。

## 旧缓存处理

旧缓存没有可靠的 App 用户归属信息，因此不自动分配给当前登录用户：

1. 读取新命名空间时只接受信封内的用户哈希、来源指纹和 schema 版本全部匹配。
2. 发现无法验证归属、格式损坏或版本不匹配时，删除对应缓存并写入当前用户的 `needs_resync` 标记。
3. 访问二课或体测时发现旧固定键，会删除旧键并标记需要重新同步，不把旧内容迁移到当前用户。
4. 新数据成功写入后，清除当前用户的 `needs_resync` 标记。

## 退出与换号顺序

`AuthProvider` 的手动退出、401 自动退出和认证用户切换均遵循以下顺序：

1. 调用 `AccountSessionCleanupCoordinator.closeCurrentSession()`。
2. 各注册上下文立即清空内存中的个人数据；AI Provider 停止 SSE 事件写回并尽力取消服务端运行。
3. 撤销服务端会话、清除本地认证凭据、Cookie 和推送 Alias。
4. 认证状态通知 `EduProvider` 与 `CourseScheduleProvider`，清除旧用户上下文并绑定新用户或空用户。

异步取消最多等待两秒；超时或失败都不会阻断本地清理和退出流程。AI 运行使用 generation 令牌丢弃切换前的后续事件。页面销毁时也会对尚未完成的 Run 做一次不阻塞的取消尝试。

## 明确不会清除的数据

阶段 0 不会在每次退出时删除所有本机数据：

- 当前用户已验证的二课、体测持久化快照不会因退出自动删除，可供同一用户下次登录后按命名空间恢复。
- 其他 App 用户命名空间下的持久化快照不会被删除，但当前用户不会读取这些命名空间。
- 与个人数据无关的主题、布局、应用设置和公共校园 AI/RAG 缓存不属于本阶段清理范围。
- 旧缓存只有在访问对应功能时才执行归属检查和删除，不进行全盘扫描。

内存中的成绩、课表、体测、二课和 AI 运行状态必须在退出或换号前关闭；持久化快照的加密保险箱迁移属于后续阶段 3。

## 验证记录

已执行并通过：`go test ./...`、`go vet ./...`、RAG Python `pytest`（2 passed）、`flutter test --no-pub`（536 passed）和 `git diff --check`。全仓 Dart 分析为 0 errors，仍有主线既有 warning/info。

阶段 0B 测试文件：

- `client/test/features/campus_data/storage/account_cache_namespace_test.dart`
- `client/test/services/account_session_cleanup_coordinator_test.dart`
