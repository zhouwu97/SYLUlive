# 客户端个人 AI 首版 RC 测试矩阵

## 自动化覆盖

| 模块 | 已覆盖 | 证据 |
| --- | --- | --- |
| Skill Registry | 固定 ID、重复 ID、未知 Skill、公开/个人分组 | `personal_skills_test.dart`、`tool_calling_test.dart` |
| 参数校验 | 多余字段、类型错误、日期越界、敏感字段递归拒绝、数量上限 | `tool_calling_test.dart` |
| 权限 | 拒绝、仅本次、低敏感会话授权、账号/Provider/字段范围变化 | `tool_calling_test.dart` |
| 预览载荷 | 先本地最小化、载荷指纹、确认后发送同一字符串 | `tool_calling_test.dart` |
| Tool Loop | 重复调用、重复 `call_id`、公共模型隔离、超时、取消、账号代际变化 | `tool_calling_test.dart` |
| 拒绝行为 | 结构化 `permission_denied`、同一轮禁止重复申请 | `tool_calling_test.dart` |
| GPA | 重修最佳成绩、缺学分、不可解析成绩、公式版本 | `deterministic_engines_test.dart` |
| 毕业 | `completed/notCompleted/unknown/blocked/notApplicable` | `deterministic_engines_test.dart` |
| 竞赛 | 硬资格阻断、证据不足、强推荐门禁 | `deterministic_engines_test.dart` |
| 运动 | 最多三次、间隔、过期体测、身体不适、极端 BMI | `deterministic_engines_test.dart` |
| Vault | `.bak/.tmp` 恢复、损坏关闭、账号隔离 | `personal_snapshot_file_backend_io_test.dart` 及既有 Vault 测试 |

## 本地结果

- 干净 `origin/main`（已合并 PR #45）重放后全量 Flutter 测试：655 项通过。
- `flutter analyze --no-pub --no-fatal-warnings --no-fatal-infos`：0 error，399 条既有 warning/info。
- `git diff --check`：通过。
- GitHub PR #46 Actions：全部检查通过。

## 尚需外部验收

- Android 真机账号切换、权限弹窗生命周期、断网、杀进程和 Vault 清除闭环。
- 不支持 Tool Calling 的第三方模型实机降级提示。
