# 模型设置页 Design QA

- source visual truth path: `C:\Users\haha\AppData\Local\Temp\codex-clipboard-165d633b-5b31-4c15-8340-1ba68a226554.png`
- global UI references: `client/lib/widgets/app_page_app_bar.dart`, `client/lib/screens/edu_grade_screen.dart`, `client/lib/widgets/campus/campus_theme.dart`
- implementation screenshot path: `E:\AI\xynewui\artifacts\ai-model-settings-menu.png`
- viewport: Android 360 × 800 logical pixels
- source pixels: 511 × 1177（包含模拟器外框，按应用内容区域判断）
- implementation pixels: 1080 × 2400，CSS/logical size 360 × 800，device pixel ratio 3
- state: 已保存配置，查询返回 7 个模型，模型选择菜单展开，当前模型已选中

## Full-view comparison evidence

- 顶部栏已从默认主题 AppBar 切换为全局 `AppPageAppBar`：暖白页面背景、居中 17px 粗体标题、56px 高度和统一返回区。
- 模型菜单不再使用默认分隔线列表；现为白色 24px 顶部圆角弹层、统一遮罩、标题/说明层级、14px 行圆角和品牌绿色选中态。
- 查询模型与测试连接为两个等宽次级按钮，保存仍是唯一主按钮，操作层级清晰。
- 模型选择弹层在 360 × 800 视口内可滚动，没有横向溢出；长模型名最多两行并省略。

## Focused region comparison evidence

- 顶部区域：背景、标题对齐、返回区尺寸均复用全局组件，无局部自定义漂移。
- 弹层区域：圆角、拖拽条、标题字重、说明色、列表间距与成绩筛选弹层使用同一视觉语言；当前项有浅绿色底和勾选状态。
- 交互区域：查询完成后 loading 在弹层出现前结束；打开选择器时不会继续进行 Tool Calling 测试。

## Required fidelity surfaces

- Fonts and typography: 使用项目 `NotoSansCJKsc`；标题、说明、模型名层级清楚，无异常换行。
- Spacing and layout rhythm: 页面 16px 边距、按钮 10px 间距、弹层 18px 内边距及 24px 圆角与全局节奏一致。
- Colors and visual tokens: 页面背景、卡片色、次文字色、品牌绿色均取自 `CampusTheme`。
- Image quality and asset fidelity: 此页面无业务图片；图标使用 Flutter Material Icons，不存在占位图或手绘资源。
- Copy and content: “查询模型”“测试连接”“选择模型”明确区分操作，说明文字明确选择后需单独测试。

## Findings

- 无 P0/P1/P2 问题。
- P3：Headless Widget 截图环境无法栅格化 Material Icons，但 release 包已包含并完成 tree-shake，定向 Widget 测试已验证图标控件及交互结构。

## Comparison history

- 首轮发现默认菜单缺少全局圆角、标题层级和选中态，同时查询与测试共用 loading（用户截图）。
- 修复后改用全局顶部栏、品牌化模型菜单，并拆分两个请求状态；最终截图未发现剩余 P0/P1/P2。

## Implementation checklist

- [x] 全局二级页顶部栏
- [x] 全局风格模型选择弹层
- [x] 查询模型与 Tool Calling 测试分离
- [x] 小屏滚动与长模型名约束
- [x] Widget 交互测试

final result: passed
