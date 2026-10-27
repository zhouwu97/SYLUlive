# 跨周调课与手动添加修复验收记录

- 日期：2026-10-27（Asia/Taipei）
- 基准提交：`01323ad99736c70d4c4c5138033e45c96d6908a8`
- 工作分支：`zhou`；工作区原有其他模块修改，本次未处理这些修改。
- 风险等级：R2，涉及本地个人课表规则字段、持久化和异步状态。
- 交付状态：已实现、定向测试已验证；未声明可发布或已部署。
- 外部动作授权：用户随后明确要求使用中文提交并推送；提交与推送结果以 Git 记录为准，未授权生产部署。

## Changed

1. 调课规则增加 `weekOffset` 和 `replaceSameCourse`，JSON 字段为 `week_offset`、`replace_same_course`。旧规则缺失字段时分别使用 0 和 false。
2. 选择原周次后可选择目标起始周。周次整体平移，保持单双周及离散周间隔；写入前验证目标学期边界、源安排和源指纹。
3. 冲突预览先撤销正在编辑的旧规则，恢复其源安排，再排除本次将移走的原周次。保存时重新检查，并完整解析候选课表后才落盘。
4. 目标已有同一 `courseKey`、相同星期和完整节次的教务原安排时，用户可明确勾选合并。手动课程、不同课程、部分重叠和其他本地调整不被合并。恢复原安排时撤销该规则产生的合并效果。
5. 调课确认页显示原周次与目标周次、保存中、失败重试；保存期间禁止重复提交。返回上一步保留草稿。异步写入后校验会话代次，防止账号或学期切换后回写旧内存。
6. 手动添加/编辑显示表单内错误和保存状态，保存成功即关闭表单，提醒同步不阻塞关闭；控制器改为在 `DialogRoute.completed` 后释放，避免退出动画中的已释放控制器异常。手动课程校验时间和学期边界，保存失败回滚当前会话的内存。

## Preserved

- 教务原始快照不被直接修改；原有的同周调课、换教室、恢复原安排、手动课程及保留冲突保存能力仍可用。
- 既有规则无需迁移；重建进程及重同步沿用原有规则存储和对齐入口。
- 未变更全局主题、原生权限策略、依赖声明、仓库权限或发布流程；未部署。

## Tests

环境：Windows 11、Flutter 3.41.8 stable；内存偏好存储和隔离的加密快照测试夹具，无真实学校凭据或教务请求。

在 `client/` 执行：

```powershell
flutter test --no-pub test/screens/course_adjustment_cross_week_test.dart test/schedule_cross_week_test.dart test/schedule_resolver_and_override_test.dart test/course_and_history_ui_test.dart test/course_schedule_provider_cache_test.dart test/course_week_swipe_test.dart test/course_schedule_cold_start_test.dart test/course_schedule_provider_term_switch_failure_test.dart --dart-define=SCHEDULE_QA_OUTPUT=E:/AI/xynewui/client/build/schedule-qa --reporter expanded
```

结果：88 项通过。最终界面微调后，调课 Widget 与课表页面两个文件的 24 项用例再次通过。最终枚举类型比较调整后，核心与调课回归的 28 项用例重跑通过。本机日志保存在 `client/build/schedule-qa/`。

```powershell
flutter analyze --no-pub lib/models/schedule/schedule_override.dart lib/providers/course_schedule_provider.dart lib/services/schedule/schedule_resolver.dart lib/services/schedule/schedule_conflict_service.dart lib/screens/schedule/reschedule/confirm_change_sheet.dart lib/screens/schedule/reschedule/course_adjustment_sheet.dart lib/screens/schedule/reschedule/select_time_sheet.dart test/schedule_cross_week_test.dart test/screens/course_adjustment_cross_week_test.dart
```

结果：`No issues found`。主课表页面另与基准提交的同目录临时副本进行静态分析对比，基准 65 项、修改后 64 项，无新增诊断；已有 unused、弃用 API 和其他异步上下文提示未在本任务中扩展清理。周次选择页已有 Radio API 弃用提示保留。`git diff --check` 通过。

### 业务验收

| 前置条件 | 操作 | 预期与实际 | 证据 |
| --- | --- | --- | --- |
| 第9、10周有课，第8周空闲 | 第9周提前一周 | 第8周新增调整后的课，第9周原课移除，第10周保留；通过 | `schedule_cross_week_test.dart` |
| 第8、9、10周同一课程同一时间 | 第9周提前到第8周，勾选合并 | 第8周显示一次，无自冲突；恢复后8、9、10周全部还原；通过 | 核心、Provider、Widget 用例 |
| 目标周有同名不同课程、部分节次重叠或另一条调整 | 预览、合并并尝试保存 | 不吞掉其他安排，其他冲突仍需明确确认；通过 | `schedule_cross_week_test.dart` |
| 连续周或单双周课程 | 整段提前一周 | 保留原有周次间隔，不补出虚假课程；通过 | 核心用例 |
| 所选原周不上课或缺少原始快照 | 进入调课 | 禁用下一步或显示同步恢复入口；通过 | Widget 用例 |
| 写入未完成、存储故障 | 连续提交、失败后重试 | 单次写入、禁用按钮、保留草稿、表单内提示，重试成功；通过 | 调课与手动添加用例 |
| 调课写入中 | 切换账号 | 拒绝旧操作回写，新会话课程与规则不被污染；通过 | Widget 与 Provider 用例 |
| 新规则已保存 | 重建 Provider、恢复加密快照、重同步教务 | 目标周次及合并标记保留，恢复原安排正常；通过 | `course_schedule_provider_cache_test.dart` |
| 手动添加名称为空或存储失败 | 添加、补填、失败重试、关闭弹窗 | 错误可见，失败回滚，重试只新增一门课，退出动画无控制器异常；通过 | `course_week_swipe_test.dart` |

### 首次失败与修复记录

- 修复前回归：同一源安排的第9周被当作自身冲突，断言期望 false、实际 true。排除移走的源周次后原用例通过。
- 手动添加链路：首次测试因设置页等待弹窗期间持续显示进度，`pumpAndSettle` 超时；测试改为在弹窗内推进必要帧。随后捕获 `TextEditingController was used after being disposed`，修复 Route 生命周期后原用例通过。
- 开发期新增测试的异步返回类型及一次局部变量位置出现过编译错误，修正后按原范围重跑通过，未删除或放宽业务断言。

## Design QA

- before：用户提供的聊天截图与上述修复前失败信号；未将聊天截图复制入仓库。
- after：真实 Flutter 渲染树输出，加载项目 NotoSansCJKsc 与打包的 MaterialIcons；本机证据位于 `client/build/schedule-qa/`，不更新 Windows canonical Golden。
- viewport：360×800，light / dark / 1.3× light / 1.5× dark；验证周次选择、目标时间、合并确认、保存中和失败重试。
- P0：所测范围未发现；主要操作、返回和保存可用。
- P1：所测范围未发现溢出或不可恢复状态；长内容通过滚动访问。
- P2：保留原有步骤1/2的视觉样式及既有 Radio 弃用项，本次未做整体视觉迁移；原生设备的字体及平台行为仍需验收。
- P3：未新增装饰动效或 canonical Golden 更新。

## Deferred

- Android：`adb devices -l` 无连接设备，`flutter emulators` 无可用 AVD；尚未完成真机/模拟器的完整用户链路验收。
- Windows 原生验收入口尝试构建失败，现有 `flutter_inappwebview_windows` 的 NuGet 依赖安装任务报 MSB3073/退出码3。未修改依赖或工具链来掩盖失败。
- Web 验收入口尝试编译失败，现有依赖链引入 `tflite_flutter` 的 `dart:ffi`，不支持 Web。临时验收入口已清理。
- 本次保证新版本读取旧规则；旧版本对新增跨周字段的降级语义未验证。未生成或签名正式发布包，R2 原生人工验收和发布门禁未完成。

恢复方式：对新建调课使用现有“恢复原安排”，保留教务原始快照；手动保存失败自动回滚当前会话内存，重试即可。整体代码回退仅处理本次文件差异，避免覆盖工作区其他修改。
