# 手机已绑定、服务器缺失登记的自动修复

- 基准：`5e731dd6f94b2b7ee704d043ed6d8bc34438f138`；风险 R2。
- 用户目标：已在手机连接教务的用户，服务器没有绑定记录时，由手机主动补请求登记，无需重新绑定。
- 根因：ensureRegistrationQueued 遇到曾保存过云端快照但服务器列表缺少对应 Provider 时，仅设置 server_missing/remote_changed 并等待手动选择，拒绝自动补发。
- 修复：完整服务器列表确认缺失，本机账号仍启用、代次与用户未改变、无解绑/换绑/冲突时，清除失效快照版本，持久化 revision=0 的新登记 Outbox，再由现有配置客户端 PUT 到服务端。兼容旧版已经标记 server_missing 的设备。
- 并发：本轮若刚确认新的 Outbox 写入，则不以可能迟到的空 GET 再次重建；下一轮重新确认。现有 409、幂等键、账号作用域、云端删除墓碑保护保持。
- 请求只含学号、类型及同步版本信息，不传学校密码/Cookie，不修改可信学生认证或旧授权标志。
- 服务端使用现有 AcademicAccountConfigHandler 持久化，无服务端代码或数据库结构变更。

## 验证

- 首轮回归失败：旧 force 同步测试出现额外 PUT（期望 1，实际 2），定位为刚完成写入后的空 GET 触发重复登记；增加本轮快照 revision 变动保护后通过。
- 新增端到端路由测试初次因测试 registry 未注册 Provider 失败，补齐已有测试 Provider 后通过；未删除或放宽断言。
- `flutter test --no-pub test/features/academic/local_academic_account_store_test.dart test/features/academic/academic_identity_projection_test.dart test/features/academic/academic_local_connection_test.dart --reporter expanded`：62 项通过。
- 定向 `flutter analyze --no-pub` 四个涉及 Dart 文件：No issues found。第一次检查有两项新增花括号提示，修复后通过。
- `git diff --check` 通过。
- 覆盖本科/研究生实际 GET→PUT→GET 模拟链路、落盘重启、重复对账、用户及代次失效、云端已删除/已换绑和现有断网重试路径。
- 未完成真实学校账号、手机真机或线上配置写入验收；本次不改 UI，无新的真实渲染状态变更。
- 本报告验证阶段尚未发布客户端；后续 Git 提交和推送不等于客户端发布，旧线上客户端不会因此自动获得修复。
