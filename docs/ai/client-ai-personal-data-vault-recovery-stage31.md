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

同一目标文件的读取、恢复、写入和类型删除会通过跨后端实例共享的
串行队列执行。队列键是目标文件的规范化绝对路径，因此读取不会把正在
进行的写入临时文件当作崩溃残留。不同账号或不同数据类型的目标文件不
共用该队列。

`deleteUser` 在对应账号的独占门内执行，等待该账号已开始的读写完成；
`deleteAll` 使用全局独占门，等待所有已开始的保险箱操作完成。后续操作
会在清理完成后按正常顺序继续，避免递归删除目录时与文件替换交错。

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
删除串行化。
