# 自定义背景与毛玻璃补齐验收

- 日期：2026-10-25
- 基准：`xianzai` / `e046124d288cd75dd723206488992618c4867a43`，未提交工作区
- 风险：R1，页面外观与渲染；没有修改 API、权限、数据存储或生产配置。
- 环境：Windows、Flutter 3.41.8、Dart 3.11.5；Android 模拟器为 API 37.1，用户启动的应用使用 software rendering / no Impeller。

## Changed

- 新增共用 `AppPageBackground`。99 个普通内容页接入同一背景入口，包括管理、工单、通知、法庭、教务、食堂、竞赛、投票、发布、组队等。页面和显式顶栏底色通过同一设置门控，加载、失败和空数据分支仍处于背景之上。
- 公共二级顶栏和竞赛主题同步接入，避免局部 Theme 再次用实色挡住壁纸。安全中心移除仅铺在 body 的重复壁纸层；简洁模式仍用表面色，文字颜色保持 onSurface。
- 管理人员概览／列表、工单统计、反馈横幅、法庭统计／选项栏、校园服务侧栏、二课验证卡、详情正文、首页与集市搜索框接入共用材质。
- 校园页头的周次徽标在开启玻璃时透出父卡片材质，不叠加第二层模糊。
- 去除玻璃装饰描边时同步去掉隐含的 border padding，修复商品封面周围残留底色。显式内容 padding 和关闭玻璃后的普通描边保留。
- 工具箱用非滚动 Wrap 替换两层 shrinkWrap GridView，保持原有列数、卡高及间距；玻璃开启时停用 Android 边缘拉伸的离屏合成。
- 课表导入预览的长周次使用剩余宽度并自动换行，不截断周次信息。

## Preserved

- 简洁模式不显示自定义壁纸；保留用户已选壁纸及毛玻璃／透明度偏好。
- 表单控制器、滚动位置、Scaffold 状态、导航、键盘、搜索、评论、分页、权限与账号切换行为。
- 图片查看器、地图、试卷及图片预览的专用内容画布保持原背景策略；根 Tab 沿用原全局背景壳。
- 原工作区的网站与 Web 端改动保留，没有混入本次客户端修复。

## Tests

证据位于忽略目录 `.evidence/background-glass/` 与 `.evidence/glass-followup/`，不更新 Windows canonical golden。

- `flutter test`：2613 项通过、6 项跳过，全量结果见 `client-tests-followup-final.txt`；首次全量的唯一失败为要求安全中心永远不透明的旧源码字符串断言。已按新需求替换为浅／深色实际组件测试，同时验证简洁模式底色与文字可读性。
- 新增页面渲染矩阵：9 个页面 × 浅色／深色／1.3 倍字号，共 27 项通过，覆盖自定义背景、切换简洁模式、关闭玻璃、搜索输入、侧栏回调、二课输入校验、投票与通知内容。
- 工具箱覆盖 360 单列与 390 双列、浅色／深色／大字号；等待页面实际使用的缩放壁纸解码后，比较拉动、有效滚动、停止、返回位置的像素，验证只有一层 Scrollable 且无 Android 拉伸层。
- 新增封面边缘几何回归，覆盖真实商品卡片、共享 surface、点击，以及关闭玻璃时恢复普通边框。
- 课程长周次在 320px、1.0／1.3／1.5 倍字号通过；修复前相同测试复现横向 overflow。
- 共用页面入口验证切换背景保留 Scaffold 状态、输入草稿和滚动位置；无 ThemeProvider 时保持原有外观。
- 核心 11 个组件／测试的 `flutter analyze` 无问题，见 `followup-core-analyze-clean.txt`。全模块分析无 error，仍有 401 条 warning／info，见 `client-analyze-background-final.txt`，没有宣称全模块 lint 清零。
- `git diff --check` 通过。

首次失败及修复记录保留：白边几何测试、周次 overflow、测试平台 override 清理、无效 ListView 参数、壁纸未完全解码的首帧、滚动采样越出卡片、无账号二课夹具、工单夹具字段、输入框保焦主动滚回。均修正测试前提或实现后重跑，未放宽像素容差、隐藏 overflow 或更新 golden 基线。

## Design QA

- P0：自动化范围内未发现操作、导航或输入阻断。
- P1：长周次越界已修复；背景切换不丢状态。
- P2：已检查代表页面实际 Flutter 栅格图。Windows headless 中部分图标／标题字形仍受既有字体路径限制，不能据此声称完成 Android 字形与全部页面的人工验收。
- P3：没有增加品牌色、圆角档位或装饰动画。

## Android 设备复验补充

> 后续修正：本节首次 ADB 检查只有一次 MOVE，不能证明进入有效持续拖动；撤回由该组三帧得出的滚动材质结论。有效手势复现、全局修复、浅／深色设备复验与背景重复问题的最新验收，见 [滚动与壁纸接缝报告](2026-10-25-glass-scroll-background-seams.md)。其余已完成的页面导航及外观检查保留为当时记录。

- 环境：2026-10-25，Pixel 8 模拟器、API 37.1、1080×2400，software rendering / no Impeller；已有管理员账号，自定义壁纸、毛玻璃开启、卡片不透明度 70%、壁纸模糊 0px、字体 100%。证据保存在忽略目录 `.evidence/glass-device-reverify/`，包含账号信息的设备截图不提交。
- 首次复验发现侧栏和二课仍显示旧界面。通过 VM Service 读取运行中 `erke_score_screen.dart` 的脚本，确认其仍是原有实色 Scaffold；普通热重载没有同步这些文件。执行 Flutter 完整 hot restart 后，重新读取脚本确认包含 `customBackground` 和透明 Scaffold 分支。此为运行代码版本不一致，不以反复热重载掩盖渲染失败。
- 用户两次按 Esc 中止桌面控制后，停止该轮控制；随后用户明确指定使用 ADB，后续全部设备导航、触摸与截图均通过 ADB 完成。

| 前置条件与操作 | 预期与实际 | 证据 |
| --- | --- | --- |
| 从“我”进入工单管理、管理人员、通知，等待实际数据加载 | 页面／顶栏显示壁纸，统计和列表卡片采用玻璃材质；实际符合 | `tickets-custom-glass.jpg`、`members-custom-glass.jpg`、`notifications-custom-glass.jpg` |
| 公众法庭切换待陪审／我的申诉 | 壁纸覆盖统计、选项栏和空状态；切换正常 | `court-jury-custom-glass.jpg`、`court-appeals-custom-glass.jpg` |
| 界面设置关闭／开启毛玻璃，再切换简洁／自定义背景 | 关闭玻璃时卡片恢复实色；简洁模式无壁纸；恢复自定义后偏好保留 | `appearance-glass-off.jpg`、`appearance-simple.jpg`、`appearance-baseline-70percent.jpg` |
| 完整重启后打开首页校园服务侧栏 | 独立壁纸与分组玻璃正常显示，内部分区不叠加白框 | `adb-drawer.png` |
| 打开工具箱，发送 DOWN→MOVE，按住下拉后截图，再发送 UP 截图 | 下拉前／按住／松手后内容材质不改变；排除状态栏后，原始 PNG 的 `(0,300)–(1080,2250)` 区域三帧像素完全一致，Pillow `ImageChops.difference(...).getbbox()` 均为 `None` | `adb-toolbox-before.png`、`adb-toolbox-held.png`、`adb-toolbox-after.png` |
| 工具箱打开二课验证页，不填写或提交密码 | 顶栏／页面壁纸和验证卡玻璃正常显示，原双密码输入仍保留 | `adb-erke.png` |
| 进入集市，等待图片加载，打开耳机招领详情 | 搜索框和卡片正文玻璃正常，封面边缘不再留白圈，详情正文透出背景 | `adb-market-loaded.png`、`adb-market-detail.png` |
| 进入校园首页 | 第9周区域继承父卡片玻璃，没有独立实色白底／白框；日期、周次与进度保留 | `adb-campus.png` |
| 首页综合打开既有投票详情，不修改投票选择 | 搜索框、列表卡片和详情正文玻璃正常，既有选择与结果保留 | `adb-feed-comprehensive.png`、`adb-poll-detail.png` |

- 本轮只追加复验证据，没有修改客户端实现，也没有重新执行已通过的 2613 项全量测试；测试结果仍以本报告 Tests 中的原日志为准。
- 复验后的 Design QA：P0/P1 在上述实际操作范围内未发现新增阻断或越界；P2 已核对 Android 的实际中文与图标、背景及玻璃材质；P3 未增加装饰元素。未将代表页面复验等同于 99 页逐页验收。
- 恢复并保留原有自定义背景、玻璃开启、70% 不透明度、0px 壁纸模糊、跟随系统和 100% 字体；未提交密码、投票、评论或管理操作。

## Deferred

- 代表页面的模拟器复验已按上节补充完成；99 页逐页验收、课程导入预览在设备上的长周次复查尚未执行，后者已有 320px／大字号 Widget 回归证据。
- 已通过 Flutter CLI 完整重启运行中的模拟器应用；没有清数据、重新登录、提交业务表单、推送或部署。
- Android GPU／Impeller、iOS 与物理设备尚未覆盖，后续可用设备上继续复验。
