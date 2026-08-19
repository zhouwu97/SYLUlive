# SYLUlive Motion Feel-check 记录

- 日期：2026-08-09
- 分支：`codex/ui-motion-consistency`
- 基线：`MCP@5ab1fa72`
- Flutter：`3.41.8`

## 当前可复核证据

| 环境 | 结果 | 覆盖 |
| --- | --- | --- |
| Windows Widget test | PASS | Root A→B→C retarget、取消/最终状态、首次 reveal、晚挂载、Reduced Motion、Feed loading/error/empty/未登录、Chat scroll intent |
| Windows/Chrome | 未连接 | 只能作为布局与状态回归辅助，不能替代真机 feel-check |
| 60Hz Android 真机 | BLOCKED | 当前工作区未连接 Android 真机 |
| 90/120Hz 设备 | 未登记 | 当前环境无对应硬件 |

## 真机补测清单

设备可用后必须登记设备型号、刷新率、Flutter 构建号，并连续执行：

- Root Tab 连续点击、A→B→C retarget、半途反向、取消。
- Feed 快速连续点击、indicator retarget、Reduced Motion。
- Chat 连续发送、键盘 ↔ Emoji、Incoming near bottom、messageFocus。

在 60Hz 真机记录完成前，不得把本分支描述为完成 physical feel-check；本记录只证明静态/Widget 层已经可复核。
