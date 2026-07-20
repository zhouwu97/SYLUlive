# 客户端个人数据保险箱阶段 3.1：中断写入恢复

## 阶段边界

本阶段只处理 `personal_vault` 文件原子替换被中断后的 `.bak` 和 `.tmp`
残留，不接入 Gateway、Skill、Tool Calling、课表或成绩数据。

## 受限恢复流程

恢复只会检查应用支持目录内的：

```text
personal_vault/<64 位小写账号哈希>/<data-type>.bin
```

候选残留文件必须完全匹配后端生成规则：

```text
<data-type>.bin.<数字时间戳>-<数字随机值>.bak
<data-type>.bin.<数字时间戳>-<数字随机值>.tmp
```

流程如下：

```text
target 存在
-> 使用 target
-> 最佳努力删除同目录的合法 .bak/.tmp

target 缺失 + 一个合法 .bak
-> .bak 原子改名为 target
-> 删除合法 .tmp
-> 按通常路径读取

target 缺失 + 只有合法 .tmp
-> 删除 .tmp
-> 返回缺失数据

target 缺失 + 多个合法 .bak
-> 失败关闭，不恢复任一文件
```

同一 `personal_vault` 根目录的读取、恢复、写入和删除会通过跨后端实例
共享的串行队列执行。队列键是保险箱根目录的规范化绝对路径，因此读取不
会把正在进行的写入临时文件当作崩溃残留，也不会与账号或全量删除交错。
保险箱保存的是小型加密快照，优先采用可证明无死锁的全根目录线性化，而
不是复杂的异步读写锁。

`deleteUser` 与 `deleteAll` 都是同一队列中的普通操作：它们等待已入队操作
完成，随后在后续读取或写入前完成删除。这样可以明确每个并发调用的顺序，
并避免“等待写者的读取任务提前计入活跃读者”造成的循环等待。

显式删除类型数据时，target 及其合法残留必须严格删除；删除失败会向调用方报告，不能伪装为成功。

## 数据流与威胁模型

恢复只返回字节，不会绕过 `AesGcmAccountScopedSnapshotStore`。恢复后的密文仍必须完成：

```text
AES-GCM 认证
-> AAD 校验
-> App 用户与来源账号校验
-> Schema、时间和内容哈希校验
```

因此篡改 `.bak`、把其他账号的 `.bak` 放入当前目录、或制造多个可恢复备份，均不会返回任何个人数据。

账号哈希必须是 64 位小写 SHA-256 十六进制值；后端不接受目录分隔符、任意路径或未匹配的备份文件名。

## 验收

```bash
cd client
flutter analyze \
  lib/features/campus_data/storage/personal_snapshot_file_backend_io.dart \
  test/features/campus_data/storage/personal_snapshot_file_backend_io_test.dart

flutter test --no-pub \
  test/features/campus_data/storage/personal_snapshot_file_backend_io_test.dart

flutter test --no-pub
git diff --check
```

必须覆盖：唯一备份恢复、target 优先、临时文件拒绝、异常多备份失败关闭、
账号目录隔离、恢复后 GCM 认证、非法路径拒绝，以及活跃写入期间的读取和
删除串行化。还必须覆盖删除已经入队后新读取或新写入进入时，所有操作都在
受限时间内完成且不会遗留 `.bak` 或 `.tmp`。
