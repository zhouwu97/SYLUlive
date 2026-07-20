# 客户端个人数据保险箱阶段 3

## 阶段边界

本阶段只建立账号隔离、可认证加密的个人快照存储，并迁移已有二课与体测缓存。

本阶段不包含：

- AI 只读 Gateway；
- 成绩、课表、体测或二课 Skill；
- Tool Calling；
- 向任意模型发送个人数据；
- 自动登录、自动刷新或后台抓取。

## 存储协议

- `AccountScopedSnapshotStore` 在构造时绑定当前 App 用户，调用方不能在读取参数中指定其他用户。
- 每个 App 用户使用独立随机 256-bit 数据密钥。
- 数据密钥和设备盐只存放在 `FlutterSecureStorage`。
- 快照使用 AES-256-GCM，12-byte 随机 nonce 和 128-bit authentication tag。
- AAD 绑定账号哈希、数据类型、信封版本和加密版本。
- 文件路径为应用支持目录下的 `personal_vault/<app-user-hash>/<data-type>.bin`。
- 密文内部保存 `app_user_id`、来源账号指纹、数据类型、SchemaVersion、EncryptionVersion、抓取时间、过期时间、内容哈希和 Payload。
- 来源账号指纹按 `SHA-256(source-system + normalized-account + device-salt)` 生成，不保存完整学号。
- Web 平台使用失败关闭的后端，不降级为明文浏览器存储。

## 迁移

迁移顺序遵循：

1. 二课；
2. 体测；
3. 课表；
4. 成绩。

本提交完成前两项：

- 新产生的二课和体测缓存只写入 AES-GCM 文件。
- 阶段 0B 已带 App 用户与来源账号元数据的明文信封，在首次读取时执行：
  `解析归属 -> 写入密文 -> 回读校验 -> 删除旧值`。
- 更早的全局旧键因无法证明归属，不自动迁移，只删除并标记重新同步。
- 课表与成绩的数据类型和统一接口已经冻结，但尚未接入；不得在未厘清现有缓存归属前直接搬运。

## 清理语义

- `deleteType` 只删除当前账号的指定数据类型。
- `clearUser` 先删除当前账号数据密钥，再清理该账号密文，实现加密擦除。
- `clearAllVaultData` 只清理保险箱前缀下的密钥、设备盐和密文，不影响登录 Token、API Key 或其他业务密钥。
- Vault 不缓存数据密钥或设备盐；每次读写只在单次调用中短暂使用密钥，因此退出登录或换号不依赖页面生命周期，也不会默认删除用户离线快照。

## 验收测试

应执行：

```bash
cd client
flutter analyze \
  lib/features/campus_data/storage/account_scoped_snapshot_store.dart \
  lib/features/campus_data/storage/personal_snapshot_models.dart \
  lib/features/campus_data/storage/personal_snapshot_file_backend.dart \
  lib/features/campus_data/storage/personal_snapshot_file_backend_base.dart \
  lib/features/campus_data/storage/personal_snapshot_file_backend_io.dart \
  lib/features/campus_data/storage/personal_snapshot_file_backend_stub.dart \
  lib/features/campus_data/storage/erke_cache_store.dart \
  lib/features/campus_data/storage/physical_cache_store.dart \
  test/features/campus_data/storage/personal_snapshot_store_test.dart \
  test/features/campus_data/storage/account_cache_namespace_test.dart

flutter test --no-pub
git diff --check
```

必须验证：

- 同设备切换 App 账号不串数据；
- 来源账号变化后不能读取旧快照；
- 文件中没有明文 Payload、完整学号或密码；
- 篡改 nonce、密文或认证 tag 后读取失败；
- 已归属旧缓存仅在密文回读成功后删除；
- 无归属旧缓存不能误迁给当前账号；
- `clearUser` 后密钥和当前账号密文均不存在。
