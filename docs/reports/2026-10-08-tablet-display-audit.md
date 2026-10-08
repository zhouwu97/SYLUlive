# Pad 大屏显示适配审核

- 日期：2026-10-08（Asia/Shanghai）
- 基准：分支 `zhou`，提交 `6e8062e8d3a9ed2682496149d6e572d57a16b861`，客户端 `1.7.6+1711`
- 范围：Flutter 客户端的首页外壳、水贴、集市、课表、校园、食堂、AI、设置、登录、文章、教务、竞赛、试卷、个人主页，以及 Android/iPad/Ohos 的设备与方向配置。
- 性质：显示适配审查；未修改业务代码、设计权威文档或发布配置。
- 阅读入口：`DEVELOPMENT_STANDARD.md`、`CONTRIBUTING.md`、`client/README.md`、`skills/sylulive-design-engineering/SKILL.md`、设计系统、动效、无障碍、Design QA 和两个 Accepted ADR。
- 工作区已有服务端、官网和发布材料修改，保持原状。

## 结论与证据边界

当前客户端属于**部分页面已有大屏适配，但布局选择、宽度预算、阅读宽度和验收矩阵尚未形成统一规则**。最明显的已确认问题是课表在 840px 断点突然变窄、集市详情旋转后保持旧布局、校园地图离开时强制竖屏，以及多个网格在横屏下仍保持两列而被大幅拉高。

本报告区分三种证据：

1. **渲染确认**：执行当前生产 Widget，在 Flutter 测试渲染器中截图并读取真实布局尺寸；业务数据使用隔离夹具。
2. **调用确认**：通过平台通道 mock 核验方向设置调用；不代表已在真机观察系统响应。
3. **静态确认／风险**：源码或配置能确认实现方式，但未完成该页面的平板生产包验收。

环境为 Windows、Flutter 3.41.8、Dart 3.11.5。没有连接 Android/iPad 真机；可用目标只有 Windows、Chrome、Edge。截图为当前 Flutter Widget 的离屏渲染，**不是 Pad 生产包截图**。课表侧栏使用 104px 占位模拟首页 NavigationRail 的占宽：当前 Material 3 默认 rail 80px，加首页左右 margin 24px；未模拟状态栏、异形屏或其他设备安全区。水贴使用当前页面和真实 `BottomNavWrapper`，外层最小 Scaffold 复现首页 `extendBody` 布局关系；未启动完整 HomeScreen。

加载了仓库的 NotoSansCJKsc Regular 字体，但 headless 环境部分标题字形和 Material Icons 仍显示方框；图片网络访问由 Flutter 测试环境阻断，菜品图显示加载／失败占位。**本报告不将方框、占位图、合成字重或跨平台像素差异判断为产品缺陷**；网格宽高、内容换行、分栏与输入位置仍可核验。没有更新 canonical Golden。

## Design QA：问题清单

### F1 · P1 · 课表在 840px 断点发生主内容挤压（渲染确认）

定位：

- `client/lib/utils/responsive_util.dart:5`：840px 起进入宽屏布局。
- `client/lib/screens/course_schedule_screen.dart:584` 和 `:732`：直接根据整窗宽度启用今日概览。
- `client/lib/screens/course_schedule_screen.dart:759`：概览宽 320px，左右 margin 合计 32px，占宽 352px。
- `client/lib/screens/course_schedule_screen.dart:3889`：网格已经正确使用局部宽度，但分栏入口缺少最小主内容宽度约束。
- `client/lib/screens/course_schedule_screen.dart:4336`：字体随列宽放大；狭窄格子仍需显示课名、地点等字段。

相同七天课程夹具的实际课程卡片宽度：

| 窗口（logical px） | 首页 rail 占位 | 文本倍率 | 卡片宽度 |
| --- | --- | --- | ---: |
| 839×1024 | 无 | 1.0 | 111.86px |
| 840×1024 | 无，符合默认悬浮导航的占宽 | 1.0 | 61.71px |
| 840×1024 | 104px | 1.0 | 46.86px |
| 840×1024 | 104px | 1.3，dark | 46.86px |
| 1024×768 | 104px | 1.0 / 1.5 | 73.14px |
| 1280×800 | 104px | 1.0 | 109.71px |

**窗口只增加 1px，卡片宽度就下降约 45%。** 课程名和地点明显密集换行；大字号进一步压缩可读内容。没有出现 RenderFlex overflow，不代表这项适配合格。

证据：[839px](assets/2026-10-08-tablet-display-audit/course-839x1024-railfalse-text1.0.png)、[840px 默认占宽](assets/2026-10-08-tablet-display-audit/course-840x1024-railfalse-text1.0.png)、[840px 模拟侧栏与 1.3× 文本](assets/2026-10-08-tablet-display-audit/course-840x1024-railtrue-text1.3.png)。

建议：由课表页面的 `LayoutBuilder` 决定是否增加概览栏，先保证七天网格的最小可读宽度；中等宽度将概览收起或移到顶部。只提高全局断点会影响水贴等其他页面，应分别按内容预算决定。可用 560px 主网格宽度作为候选起点，再用长课名和大字号验证，不能直接视为冻结标准。

### F2 · P1 · 校园地图退出后强制应用竖屏（调用确认）

定位：`client/lib/screens/campus_map_tab_page.dart:24` 和 `:34`。

页面按钮请求横屏后，`dispose()` 请求 `DeviceOrientation.portraitUp`，不是恢复原有方向策略。平台调用记录为：

```text
[landscapeLeft, landscapeRight]
→ 页面销毁
→ [portraitUp]
```

平板本来处于横屏时，这个全局调用可能让退出地图后的页面被转回竖屏并保持方向限制。当前按钮状态来自 `_isLandscape`，也未绑定窗口实际方向；系统旋转与按钮显示可能不一致。

建议：方向限制由应用统一策略管理，页面退出恢复原策略；平板优先尊重系统旋转。具体系统响应还需 Android Pad / iPad / 鸿蒙真机确认。

### F3 · P2 · 集市详情在旋转／分屏变化后保持旧布局（渲染确认）

定位：`client/lib/screens/market_screen.dart:1186`、`:1194`，`client/lib/screens/post_detail_screen.dart:2722`。

`isDesktopSplitMode` 在 `Navigator.push` 时计算一次，详情页依据这个固定参数选择布局：

| 操作 | 打开时布局 | 调整窗口后实际布局 |
| --- | --- | --- |
| 1280px 打开 → 缩到 600px | 左内容／右图片双栏 | 仍保持双栏 |
| 834px 打开 → 扩到 1280px | 手机单栏 | 仍保持单栏 |

600px 下即使商品无图片，空的图片栏仍占约 44% 宽度，评论与输入区域被压在左栏。当前 600px 场景未出现 overflow，因此按 P2 记录；更窄窗口、长文案及键盘场景可能升为 P1，需要补测。

证据：[1280 → 600](assets/2026-10-08-tablet-display-audit/market-detail-1280-to-600.png)、[834 → 1280](assets/2026-10-08-tablet-display-audit/market-detail-834-to-1280.png)。

建议：在详情页 build 内根据实际约束重新决定内容布局；区分“嵌入主从视图”的路由语义和“当前宽度足够双栏”的布局语义，避免旋转时顺带改变返回行为。

### F4 · P2 · 食堂、集市固定两列，横屏卡片过大（渲染确认）

定位：

- `client/lib/screens/canteen_dish_list_screen.dart:135`：固定两列，宽高比 0.82。
- `client/lib/screens/canteen_screen.dart:725`：热门菜品固定两列，宽高比 0.92。
- `client/lib/screens/market_screen.dart:725`：瀑布流固定两列。

1280×800 的离屏实测：

| 页面 | 单卡宽高 | 首屏效果 |
| --- | --- | --- |
| 菜品图库 | 616×751.22px | 菜名位于 y≈776，实拍张数需要继续滚动；首屏几乎由两张图占满 |
| 集市网格 | 618×712px | 两张商品卡占用大量首屏面积，大屏未提高浏览密度 |

834×1194 的菜品卡为 393×479px，集市卡为 395×489px。卡片在宽屏上主要被等比放大，列数不变。

证据：[菜品图库](assets/2026-10-08-tablet-display-audit/dishes-landscape.png)、[集市](assets/2026-10-08-tablet-display-audit/market-landscape.png)。图片内容为测试占位，不用于判断图片清晰度。

建议：按页面局部宽度和目标卡片宽度计算列数；平板横屏尝试 3–4 列，用真实长标题、价格、错误图和加载占位验证。热门菜品与发布图片网格也应纳入同一轮尺寸审查，不宜仅把 `2` 全局替换为 `4`。

### F5 · P2 · AI 页缺少阅读限宽，能力卡也随屏幕拉高（渲染确认＋静态确认）

定位：

- `client/lib/screens/ai/ai_assistant_screen.dart:1364`：内容 Column 填满窗口。
- `client/lib/widgets/ai/ai_empty_state.dart:74`：两列、宽高比 1.62。
- `client/lib/widgets/ai/ai_personal_empty_state.dart:109`：个人助手同样固定两列。
- `client/lib/widgets/ai/ai_message_card.dart:45`：用户消息采用窗口宽度的 78%，助手正文没有共同阅读宽度上限。

1280×800 时，输入框宽 1180px；公共能力卡约 619×382px，少量文字置于卡片上部，首屏只能看到第一排，后续能力需要滚动。834px 时输入框已宽 734px。长回答与用户消息的具体行长只完成静态审查，未生成真实会话内容截图。

证据：[AI 横屏](assets/2026-10-08-tablet-display-audit/ai-landscape.png)。测试配额与设备权限状态为夹具，不能据此判断线上 AI 可用性。

建议：限制会话正文和 composer 的共同阅读宽度；能力入口按局部宽度增加列数或使用内容高度，而非在大屏上持续放大卡片。历史列表可在宽度足够时作为辅助栏，仍需保留当前 loading/error/retry 与个人数据权限语义。

### F6 · P2 · 内容限宽没有推广到主要阅读／表单页面（静态确认）

`ResponsiveUtil.getMaxContentWidth()` 定义了 tablet 800 / desktop 1200，但仓库生产代码没有调用者；`isTablet()` 也没有实际页面调用。多数页面只调整固定边距后直接铺满窗口：

| 模块 | 当前实现入口 | 可能影响 |
| --- | --- | --- |
| 登录／注册 | `login_screen.dart:549` 的 SafeArea + SingleChildScrollView | 输入框与按钮过宽，表单焦点松散 |
| 校园首页 | `campus_screen.dart:409` | 今日信息、新闻列表横向展开；服务网格本身已自适应 |
| 校园文章 | `campus_article_detail_screen.dart:274` | 正文阅读行长过长 |
| 成绩中心 | `edu_grade_screen.dart:1033`、`:1193` | 统计与课程信息继续以全宽纵向列表组织 |
| 竞赛中心 | `competition/competition_center_screen.dart:609` | 搜索、概览与赛事列表缺少统一阅读宽度 |
| 我的首页 | `profile_screen.dart:264` | 与已做双栏的用户主页存在不同大屏布局策略 |
| 试卷列表／投稿 | `exam_papers/` | 已有小屏 responsive 测试，尚未形成 Pad 限宽验收 |

这些属于代码证据支持的视觉风险，**未逐个页面完成 Pad 生产渲染，不按已复现 overflow 报告**。

建议：建立阅读、表单、图库、主从分栏四类内容宽度规则，并优先复用 `SettingsPageScaffold` 的 Center + ConstrainedBox 模式。图库和课表需要利用大屏空间，不适合统一强行缩成手机宽度。

### F7 · P2 · 导航与各页面分栏条件缺少共同宽度预算（静态确认＋部分渲染确认）

定位：`home_screen.dart:1898`、`shuitie_screen.dart:1319`、`chat_list_screen.dart:177`、`user_home_screen.dart:350`、`responsive_util.dart:5`。

- 全局宽屏断点 840px；私信 720px；用户主页按局部宽度 820px；通用 PostCard 的部分视觉参数在 600px 改变。这些数值不同本身不构成 bug，问题是没有说明各自所需的内容预算和嵌套时的处理方式。
- `ThemeProvider` 默认 `BottomNavStyle.floating`、`floatingNavBar=true`。首页仅在宽屏且关闭悬浮导航时显示 rail，而水贴独立根据整窗宽度切双栏。
- 768 / 800 / 834px 竖屏平板一般仍沿用首页手机外壳；840px 才突然启用课表概览和水贴分栏。
- 水贴主列表固定 380px。在 840px 窗口模拟首页 rail 后，详情仅剩 356px；若加入系统安全区还可能更窄。
- 悬浮导航没有最大宽度：1280px 下 Dock 约 1256px，一项约 251px，导航图标和标签在大屏上非常分散。

水贴已测的默认悬浮模式在 840×1024 下，输入框 y=898–942、导航区域 y=948–1024；1280×800 下分别为 y=674–718、y=724–800。**这两个无键盘、未登录场景没有回复框遮挡。** 模拟 rail 的 840px 场景也可渲染，无 overflow，但输入框宽度从 346px 缩到 242px。

证据：[默认水贴外壳](assets/2026-10-08-tablet-display-audit/water-split-840-railfalse.png)、[模拟 rail 占宽](assets/2026-10-08-tablet-display-audit/water-split-840-railtrue.png)。

建议：由首页提供实际内容宽度，页面按自己的最小主栏／详情栏宽度决定分栏；将导航偏好与宽度适配明确组合。两种导航风格都要纳入大屏验收，保留用户已有偏好。

### F8 · P2 · Pad 不在正式视觉基线矩阵中（文档与测试静态确认）

定位：`docs/design/DESIGN_QA.md:37`、`client/test/helpers/golden_viewport.dart:11`。

当前 canonical 矩阵只有 360×800、390×844、360px dark、360px 1.3×。少数 Widget 用例采用宽窗口或横屏，但不足以覆盖关键分栏边界。`exam_paper_responsive_test.dart` 主要检查 320px；私信相关测试在当前功能开关下跳过。

建议：专项补充 600 / 768 / 834 / 839 / 840 / 1024 / 1280px，并测试打开详情后的连续 resize；同时覆盖导航风格、键盘、大字号、状态恢复和草稿。修改冻结矩阵应更新设计权威文档并遵循其 Golden 平台规则，本次未改该合同。

## 已有适配与平台范围

| 能力 | 现状 | 本次判断 |
| --- | --- | --- |
| 设置中心 | `SettingsPageScaffold` 内容 maxWidth 680 | 已做阅读限宽；1280px 渲染确认 |
| 工具箱 | maxWidth 1000，按局部约束选择 1–4 列，卡片 mainAxisExtent 88 | 结构正确，静态确认 |
| 校园服务网格 | 根据局部 width 选择 3／4／6 列 | 已有自适应实现，静态确认 |
| 水贴版块页 | 部分列表 maxWidth 680 | 已有限宽，可复用；静态确认 |
| 用户主页 | LayoutBuilder 的局部宽度触发双栏 | 比整窗判断更适合被嵌入详情栏，静态确认 |
| 私信 | 720px 起列表／详情分栏，文本气泡上限 420px | 代码存在；`PrivateChatPolicy.enabled=false`，当前不可作为线上已开放能力 |
| Android | MainActivity 可 resize，监听 orientation / screenSize，无主 Activity 固定竖屏声明 | 没有发现主 Activity 阻止横屏的配置；地图存在全局方向副作用 |
| iPad | `TARGETED_DEVICE_FAMILY=1,2`；配置四种 iPad 方向 | 项目配置纳入 iPad，未做 iPad 构建／真机验证 |
| HarmonyOS NEXT | `client/ohos/entry/src/main/module.json5:7` 只有 `phone`；测试矩阵仍写平板适配待 UI 阶段 | 如目标为原生鸿蒙 Pad，需单独确认 tablet 设备声明、HAP 分发与真机支持；不能据当前手机 HAP 宣称 Pad 已验收 |

HarmonyOS 项不是已复现的 Flutter 显示 bug，而是条件性的支持／验收缺口。Android 兼容层和平板原生 HarmonyOS NEXT 应分别验证。

## Tests：已执行与限制

### 原有定向回归

在 `client/` 执行：

```powershell
flutter test --no-pub test/screens/canteen_dish_list_screen_test.dart test/screens/market_screen_filter_test.dart test/screens/ai/ai_assistant_screen_test.dart test/screens/campus_map_tab_page_test.dart test/screens/exam_paper_responsive_test.dart test/course_week_swipe_test.dart --reporter compact
```

结果：**26 个通过**。涵盖菜品正常／无图／空数据、集市筛选与搜索切换、AI 主题与账号会话隔离、地图资产、试卷小屏、课表切周与缓存／开学周及研究生大字号等已有回归。它们不替代平板生产包业务验收。

### 专项渲染与交互探针

诊断脚本位于本机 `client/build/tablet-audit/`，复用当前页面及现有隔离夹具；该目录为构建／诊断材料，不加入业务代码。

| 脚本 | 覆盖 | 最终结果 |
| --- | --- | --- |
| `course_audit_test.dart` | 7 组断点／rail 占宽／大字号／主题尺寸 | 7 组完成，记录宽度，无 layout exception |
| `widgets_audit_test.dart` | 5 页面 × 4 视口，菜品空态／失败重试，地图方向调用 | 23 组完成 |
| `market_detail_audit_test.dart` | 1280→600、834→1280 | 2 组完成，确认旧分栏状态未改变 |
| `feed_audit_test.dart` | 默认悬浮 840 / 1280，模拟 rail 的 840 | 3 组完成，确认输入位置与窄详情尺寸 |

合计 **35 组专项探针完成**。诊断完成并不表示上述设计问题通过验收。20 组页面视口记录未捕获布局异常；菜品失败用例验证重试入口与再次失败可恢复展示，没有声称覆盖真实服务重试成功。

视口：834×1194 light 1.0、1280×800 light 1.0、600×800 dark 1.3、480×600 light 1.5；课表追加 839 / 840 / 1024 边界。未模拟设备像素密度、生产键盘和异形屏。

数据与最终验证记录：[measurements.json](assets/2026-10-08-tablet-display-audit/measurements.json)、[课表](assets/2026-10-08-tablet-display-audit/verification.md#course-results-final)、[页面矩阵](assets/2026-10-08-tablet-display-audit/verification.md#widgets-results-retry)、[详情 resize](assets/2026-10-08-tablet-display-audit/verification.md#market-detail-results)、[水贴](assets/2026-10-08-tablet-display-audit/verification.md#feed-results-final-rail)。

### 静态分析

对 11 个关键源码入口执行定向 `flutter analyze --no-pub`。结果：**0 error，7 warning，73 info，命令退出非零**；问题为当前工作区既存的未使用成员／import、空断言、弃用 API 和 async context 等。不是全仓 analyze 通过，也不把这些信息全部归为大屏缺陷。

验证记录：[analyze-results.log](assets/2026-10-08-tablet-display-audit/verification.md#analyze-results)。

### 诊断过程的失败记录

保留了首次失败，未将其当作产品缺陷：

- 专项文件首次生成存在工作目录路径错误，随后修正；无生产源码改变。
- 页面矩阵首次执行缺少图片缓存 path_provider mock，加上全局错误处理覆盖与地图加载等待，产生测试环境异常；终止该测试进程、补齐 mock 并用有界 frame pump 后重跑。原始失败记录见 [widgets-results.log](assets/2026-10-08-tablet-display-audit/verification.md#widgets-results)。
- 水贴探针最初遗漏夹具 `_FeedTestPage`、AuthProvider token，造成编译或 mock 错误，并连带出现异常 ErrorWidget 的巨大 overflow；修正夹具后原场景无 overflow。该异常不计入产品 P0/P1。原始失败记录见 [feed-results.log](assets/2026-10-08-tablet-display-audit/verification.md#feed-results)、[feed-results-retry.log](assets/2026-10-08-tablet-display-audit/verification.md#feed-results-retry)。
- 新增模拟 rail 场景时探针仍无条件读取已不存在的 BottomNav，导致探针失败；改为读取可选导航后 3 组完成。原始失败记录见 [feed-results-rail.log](assets/2026-10-08-tablet-display-audit/verification.md#feed-results-rail)。
- 早期课表 rail 占位按 96px 估算，核对本地 Material 3 实现后修正为 104px 并重跑；本报告与保存截图使用最终结果。

## 建议修复顺序

1. **先处理宽度与方向的行为问题**：课表主栏预算、集市详情动态 resize、地图退出恢复方向策略。定向回归后再走真实 Pad 链路。
2. **再处理明显显示问题**：食堂／集市网格列数，AI 正文和输入限宽，能力卡高度；用真实内容确认信息密度。
3. **形成共用规则**：首页内容约束与导航偏好组合，阅读／表单／图库／主从页面分类，逐页迁移。
4. **补齐 Pad 验收**：关键断点、dark、1.3×、高风险 1.5×、键盘／表情／图片、登录权限、异步切换及真机旋转；若目标包含原生鸿蒙 Pad，再补设备声明与平台验证。

这些方向应以最小修改范围逐项落实，不需要先重写所有页面或改品牌／动效体系。

## Changed / Preserved / Deferred

**Changed**：新增本次审核报告、12 张精选离屏证据图、尺寸数据与诊断日志。

**Preserved**：客户端业务代码、设计 ADR、canonical Golden、平台发布配置均未修改；工作区其他任务的改动保留；未提交、推送或部署。

**Design QA 汇总**：本次覆盖范围未确认 P0；P1 为 F1 课表主内容挤压、F2 地图全局方向副作用；P2 为 F3–F8；没有为轻微装饰单列 P3。

**Deferred**：真实 Pad 生产包验收、登录后发送与权限提示、软键盘／表情面板、导航模式切换时草稿／滚动保留、网络中请求 resize 与账号竞态、iPad／Android OEM／鸿蒙系统方向响应、折叠屏 display features、渲染性能与 GPU blur 成本。已有回归可以提供局部状态证据，不能证明这些 Pad 组合场景完成。
