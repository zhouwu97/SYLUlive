# Android 权限台账

| 权限/配置 | 当前用途 | 请求时机 | 拒绝后的降级 | Debug | Release | 结论 |
|---|---|---|---|---|---|---|
| `POST_NOTIFICATIONS` | 远程/本地通知展示 | 对应功能启用时 | 不展示通知，不影响基础功能 | 按需 | 按需 | 保留 |
| `SCHEDULE_EXACT_ALARM` | 课程/考试提醒 | 用户启用精确提醒时 | 使用非精确提醒或提示用户 | 按需 | 按需 | 保留并按需 |
| `RECEIVE_BOOT_COMPLETED` | 恢复本地提醒/保活 | 系统广播 | 不恢复后台任务 | 是 | 是 | 保留，链路分开门控 |
| `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` | 用户主动开启保活 | 设置页 | 保活稳定性下降 | 按需 | 按需 | 保留并按需 |
| `WAKE_LOCK` | 保活/提醒 | 对应任务运行时 | 任务可能延后 | 是 | 是 | 保留 |
| `FOREGROUND_SERVICE*` | 前台保活服务 | 用户主动开启保活 | 不启动保活 | 是 | 是 | 保留并按需 |
| `REQUEST_INSTALL_PACKAGES` | 用户主动安装应用更新 | 点击安装时 | 使用浏览器/手动更新 | 是 | 是 | 保留并按需 |
| `READ_MEDIA_IMAGES`/Photo Picker | 图片选择 | 用户选择图片时 | 选择器降级 | 是 | 是 | 优先 Photo Picker |
| `READ_MEDIA_VIDEO` | 当前未核验到真实视频功能 | 不应请求 | 无 | 否 | 否 | 待确认后删除 |
| `usesCleartextTraffic` | 本地联调 | Debug | Release 默认禁止明文 | 是 | 否 | 分离配置 |
