# 主题商城实施计划

| 文档 | 作用 |
| --- | --- |
| [ADR-005](adr/005-theme-package-and-store.md) | 产品决策 |
| [主题包格式契约](theme-pack-contract.md) | 格式、Token、推导规则、对比度规则、错误码。实现以它为准 |
| [制作与审核细则](theme-creation-guide.md) | 作者规范、审核规程、官方主题参数 |
| 本文 | 实施步骤与验证标准 |

本文写给实施者。按阶段顺序执行，每个阶段单独提交，并附第 12 节格式的交付报告。

## 0. 工作方式

- 开工前阅读 `AGENTS.md`（尤其是「实现取舍：不过度防御」一节）、`DEVELOPMENT_STANDARD.md`、`CONTRIBUTING.md`，并记录 `git status --short`、当前分支和 `HEAD`。
- 保留其他任务的未提交修改，只暂存本阶段改动的文件。没有明确授权时，不推送、不部署、不做生产迁移。
- 本计划给出的测试文件就是全部要新增的测试文件。用例写在这些文件里，不要再另外新建测试文件。
- 整个方案只在一处计算哈希：商城规范包的 SHA-256。服务端生成规范包时计算一次，客户端下载完成后核对一次。其他任何地方都不计算哈希、不保存哈希。
- ZIP 条目的 CRC32 校验属于 ZIP 格式本身的要求，必须做。`archive` 4.2.0 不会自动校验，要对每个读取的条目调用 `ZipFile.verifyCrc32()`。

## 1. 范围

**本计划交付**：

- 语义 Token 化，覆盖九个首批页面；
- `.sltheme` 主题包，以及本机导入、导出、试用和回退；
- 页面壁纸与底栏图标；
- 单套 UI 内的页头布局、卡片样式、图片效果与装饰贴纸；
- 自定义字体、桌面启动图标、桌面小部件跟随主题配色；
- 主题工坊；
- 服务端投稿、审核、目录、下载、下架；
- 客户端主题商城；
- 首批官方主题；
- 移动网页应用主题。

**不做**：

- 鸿蒙端；
- 第二套 UI 风格、任意组件树、脚本式主题；
- 界面文案替换；
- 付费；
- 评论；
- 多份外观历史，只保留"上一个外观"；
- 工坊的撤销和重做。

### 1.1 单套 UI 的完整交付边界

本期只维护现有的一套共享组件和交互语义。页头模板、卡片参数和装饰属于这套 UI 的配置，不建立第二套页面实现。具体字段、范围、颜色矩阵规则和默认值只在格式契约第 2.7–2.9 节维护。

| 范围 | 必须支持 | 验收边界 |
| --- | --- | --- |
| 九个首批页面 | 明暗 Token、字体、适用的圆角；共享内容卡片跟随 `AppCardStyle`（`cardStyle`） | 从每个入口进入真实页面；同时检查弹层、输入区、loading、empty、error、retry、权限不足和异步返回状态 |
| 首页、校园、我 | 三种页头模板、对齐、图片区尺寸、背景与贴纸 | 共用页头呈现组件；默认不新增空白图片区；紧凑和沉浸模板不隐藏业务信息或功能入口 |
| 课表、个人主页、AI、工具箱、设置、集市 | 各自适用的主题外观 | 课程色块保留课程语义，个人主页保留原用户封面，用户内容图片不滤色，分类和状态固定色按已确认边界保留 |
| 顶栏、底栏、弹层、键盘上方输入区 | 跟随各自 Token 和 AppShape | 三种底栏材质都验证；液态玻璃的 shader 路径与基础路径均覆盖；不把通用卡片参数套给原生系统控件 |
| 外观完整生命周期 | 工坊编辑 → 导出 → 本机导入／试用 → 应用 → 重启 → 恢复 → 投稿审核 → 商城下载 | 布局、材质、图片效果、贴纸位置与层次不得在任一环节丢失；按分组应用不覆盖未选分组 |
| Android、iOS、桌面与移动网页 | 各平台支持的主题字段 | App 内自定义参数完整生效；系统图标、小部件按原有平台边界；移动网页在 P6 首批完成配色、壁纸（CSS `filter`）和字体，桌面网页维持现状 |

“完整”不扩大为全仓库页面改版。首批范围外页面、原生文件选择器／裁剪器、系统权限弹窗保留平台或原有外观，不能在交付报告里写成已主题化。P0 仍只执行已经确认的 Token 迁移与门禁；新增参数的模型与持久化在 P1 完成，页头布局、装饰和卡片样式渲染在 P1.6 完成，编辑在 P2 完成。

## 2. 现状定位

| 内容 | 位置 |
| --- | --- |
| 外观偏好 | `client/lib/providers/theme_provider.dart`。偏好 key 是类内的 `_xxxKey` 常量；卡片不透明度范围以[格式契约](theme-pack-contract.md)为准 |
| 颜色常量 | `client/lib/theme/app_colors.dart`，全部为 `static const` |
| ThemeData | `client/lib/theme/app_theme.dart`：`ColorScheme.fromSeed(seedColor: AppColors.brandPrimary)`，暗色 `primaryColor` 固定为 `#7ED6C5` |
| Token 访问器 | `client/lib/theme/app_theme_tokens.dart` |
| 校园配色 | `client/lib/widgets/campus/campus_theme.dart` |
| 圆角 | `client/lib/theme/app_radius.dart`：sm 8、md 12、lg 16、sheet 24、pill 999 |
| 课程色 | `client/lib/screens/course_schedule_screen.dart` 的 `courseColors`（5 色）和 `getCourseColor` |
| 底栏 | `client/lib/widgets/liquid_bottom_nav.dart` 的 `labels`、`icons`；`floating_bottom_nav.dart` 复用它们；`bottom_nav.dart` 在两者间切换 |
| 壁纸渲染 | `client/lib/widgets/global_background_wrapper.dart` |
| 当前根页签 | `client/lib/utils/app_navigator.dart` 的 `currentHomeTabIndex`（0 首页、1 集市、2 课表、3 校园、4 我） |
| 外观设置页 | `client/lib/screens/settings/appearance_settings_screen.dart` |
| 原生深链 | `client/android/.../MainActivity.kt` 的 `DEEPLINK_CHANNEL` |
| 已有依赖 | `archive` 4.2.0、`file_picker`、`share_plus`、`image` 4.9.2、`path_provider`、`package_info_plus` |
| 表情商城（可复用） | 客户端 `client/lib/features/emoji/`（下载管理 `emoji_pack_download_manager.dart`）；服务端 `server/cmd/emoji_pack_routes.go`、`handlers/emoji_pack_submission.go`（错误码写法）、`services/emoji_pack_service.go`（暂存目录 → rename、配额、事务、启动清理）、`services/emoji_image_service.go`（`resizeToMax`、PNG 编码） |
| 举报 | `server/internal/handlers/report.go`、`client/lib/widgets/report_sheet.dart` |
| Web Token | `web/tokens.css` |

**九个首批页面**：

| 页面 | 文件 |
| --- | --- |
| 首页 | `shuitie_screen.dart`（信息流），`home_screen.dart`（导航外壳与发布按钮） |
| 集市 | `market_screen.dart` |
| 课表 | `course_schedule_screen.dart`、`screens/schedule/` |
| 校园 | `campus_screen.dart` |
| 我 | `profile_screen.dart` |
| 个人主页 | `user_home_screen.dart` |
| AI 助手 | `screens/ai/` |
| 工具箱 | `toolbox_screen.dart` |
| 设置 | `settings_screen.dart`、`screens/settings/` |

**连带迁移的共享组件**：`liquid_bottom_nav.dart`、`floating_bottom_nav.dart`、`post_card.dart`、`market_post_card.dart`、`home_service_drawer.dart`、`widgets/campus/`、`widgets/settings/`、`widgets/ai/`、`widgets/course/`。

## 3. P0 语义 Token 化（默认外观与已确认的颜色统一）

### 3.1 步骤

1. **截取迁移前的基线。** 在迁移前的提交上，写一个临时比对测试 `client/test/theme_parity/parity_test.dart`：
   - 本次试点为首页、设置页和帖子卡片，视口 390×844，亮色和暗色共六张，使用 `test/helpers/` 中已有的 fixtures；其余页面迁移时再建立对应的明暗基线；
   - 运行 `flutter test test/theme_parity --update-goldens`。
   - 整个 `client/test/theme_parity/` 目录加入 `.gitignore`；P0 完成后移出测试目录，不提交。最终六张试点基线保存到 `artifacts/theme-p0/baseline/`，该目录只保留图片。
2. **新增 `client/lib/theme/app_palette.dart`**：
   - `AppPalette extends ThemeExtension<AppPalette>`，字段为契约第 3 节的全部 Token，加上 `coursePalette`；
   - `lerp` 中，颜色用 `Color.lerp`，色板在 t 小于 0.5 时取 a、否则取 b；
   - 提供 `AppPalette.defaults(Brightness)`，值等于契约第 3 节。"P0 回填"的项，取迁移前代码中的实际值，并写回契约的表格；
   - 提供 `AppPalette.fromJson(Map)`，供 P1 读取 manifest 的 `tokens` 使用。
3. **在同一个文件中新增 `AppShape extends ThemeExtension<AppShape>`**：
   - 档位为 `compact`、`standard`、`rounded`，系数分别为 0.75、1.0、1.35；
   - 提供 sm、md、lg、sheet 四个 getter，pill 不乘系数；
   - 首批页面中的 `AppRadius.*` 改为 `AppShape.of(context).*`。
4. **改造 `AppTheme`**：
   - 新增 `AppTheme.build({brightness, palette, shape, seedColor, variant})`，`lightTheme`、`darkTheme` 改为用默认参数调用它。
   - **默认路径保持现有 `ColorScheme`**：没有应用主题配色（`theme_appearance_v1.colors` 为 null）时，`ColorScheme` 仍然只由 `ColorScheme.fromSeed(seedColor: AppColors.brandPrimary, brightness)` 生成，不做任何覆盖。现有方案的亮色 `primary` 是 `#006A61`、`surface` 是 `#F4FBF8`，与 Token 默认值（`#147C72`、`#FFFAF4`）不同；按钮、顶栏这些读取 `scheme` 的控件，P0 之后颜色必须保持不变。
   - **应用了主题配色时，Token 同步进入 `ColorScheme`**：先用主题的 `seedColor` 和 `schemeVariant` 生成颜色方案，再用 `copyWith` 把 Token 覆盖进去，对应关系如下：

     | ColorScheme 角色 | Token |
     | --- | --- |
     | `primary`、`onPrimary`、`primaryContainer`、`onPrimaryContainer` | 同名 Token |
     | `surface` | `background` |
     | `onSurface` | `textPrimary` |
     | `onSurfaceVariant` | `textSecondary` |
     | `surfaceContainerLowest` | `card` |
     | `surfaceContainerLow` | `surface` |
     | `surfaceContainerHigh` | `surfaceElevated` |
     | `surfaceContainerHighest` | `surfaceMuted` |
     | `outline` | `outline` |
     | `outlineVariant` | `divider` |

     现有组件主题（`app_theme.dart` 约第 98–170 行的按钮、TabBar、进度条、开关、滑块）都读 `scheme.primary`，覆盖之后会自动跟随主题，不需要逐个改。
   - 官方主题"沈理青"以 Token 默认值加上上表的映射来渲染，所以按钮会变成 `#147C72`，属于 P5 验收的有意视觉变化。
   - `primaryColor`、`scaffoldBackgroundColor`、`canvasColor` 和分割线颜色改为从 palette 读取。
   - 默认路径的 `ColorScheme` 与现在完全相同，由像素比对来证明。
5. **`AppThemeTokens`** 的每个 getter 改为读取 `Theme.of(context).extension<AppPalette>() ?? AppPalette.defaults(Theme.of(context).brightness)`，原有公开接口不变，并为新 Token 补充 getter。
6. **`CampusTheme`**：
   - 现有的静态字段和 `cardDecoration(bool)` 原样保留，值不变。九个首批页面以外还有 21 个文件、168 行在 const 表达式中调用它们，这些调用在 P0 中不改。
   - 首批页面范围内的调用，改为通过 `AppThemeTokens.of(context)` 读取品牌、表面、文字、边框颜色。
   - blue、orange、green、cyan、red、dining 这几个功能识别色保持不变。
   - 首批范围以外的页面，在以后扩大主题化范围时再迁移。
7. **课表**：`getCourseColor` 增加参数 `List<Color> palette`，调用方传入 `AppThemeTokens.of(context).coursePalette`。
8. **先做试点**：只迁移首页、设置页和 `post_card.dart`。然后在测试里临时注入一套明显不同的 palette（例如把 primary 设为品红），确认这三处的页面背景、文字、按钮、开关全部变色，没有遗漏的控件。本次 P0 提交先验收这三处试点并等待确认；其余页面迁移时再执行全范围门禁。
9. **迁移页面和组件**：
   - `Color(0x…)` 字面量，以及 `AppColors` 中品牌、表面、文字、边框、输入、聊天、首页角标类的常量，替换为 Token；
   - 状态色继续使用 `AppColors`；
   - 和主题无关的纯装饰色保留原值，并在行尾加注释 `// theme: fixed`；
   - 读取 context 后不能再用 `const` 的地方，去掉 `const`。

已确认的试点颜色统一：

- 首页暗色背景使用 `background`；首页帖子正文使用 `textPrimary`；设置页暗色标题和副标题使用 `textPrimary`、`textSecondary`；首页发布按钮使用 `primary`、`onPrimary`；设置开关选中圆钮使用 `onPrimary`，未选中圆钮使用 `textPrimary`。
- 这些角色使用契约现有 Token，接受对应的颜色变化，不新增 Token。更新对应基线前保存改动前后截图，其他截图保持零像素差。
- 试点扫描包含 `shuitie_screen.dart`、`home_screen.dart`、`settings_screen.dart`、`post_card.dart` 和 `widgets/settings/`；状态、分类识别色及固定预览底图保留现值，并标明 `// theme: fixed`。
- 缺少扩展的局部 `Theme(data: ...)` 使用当前明暗模式的默认调色板及标准圆角，不要求测试壳挂载 `AppTheme`。

### 3.2 验证标准

| 项 | 方法 | 通过条件 |
| --- | --- | --- |
| 外观不变 | 在迁移后运行 `flutter test test/theme_parity` | 本次六张试点截图除上述已确认的颜色统一外，零像素差。只更新受确认变更影响的基线，其他基线不更新 |
| 迁移完整 | 本次先运行试点扫描，其余页面迁移后运行下方全范围扫描 | 迁移前确认命中已知颜色；迁移后对应范围输出为空。两次的命令和输出都写进报告 |
| 静态检查与回归 | `flutter analyze`；`flutter test --reporter compact` | 没有新增问题；全部通过 |
| 真机 | 中端 Android 机，亮暗模式下打开当前迁移页面；全部迁移后覆盖九个页面 | 除确认的颜色统一外，与迁移前一致 |

颜色扫描排除 `campus_theme.dart` 中按第 3.1.6 条保留的兼容实现；该文件的新增 Token 装饰路径单独扫描，旧静态字段与 `cardDecoration(bool)` 对照迁移前源码核验原值。

扫描命令如下。表达式中的 `|` 是正则的"或"，不能写成 `\|`：

```bash
cd client && rg -n -g '!campus_theme.dart' -e 'Color\(0x' -e 'AppColors\.(brand|surface|text|border|composer|searchBar|message|feed)' lib/screens/shuitie_screen.dart lib/screens/home_screen.dart lib/screens/market_screen.dart lib/screens/course_schedule_screen.dart lib/screens/schedule lib/screens/campus_screen.dart lib/screens/profile_screen.dart lib/screens/user_home_screen.dart lib/screens/ai lib/screens/toolbox_screen.dart lib/screens/settings_screen.dart lib/screens/settings lib/widgets/liquid_bottom_nav.dart lib/widgets/floating_bottom_nav.dart lib/widgets/post_card.dart lib/widgets/market_post_card.dart lib/widgets/home_service_drawer.dart lib/widgets/campus lib/widgets/settings lib/widgets/ai lib/widgets/course | rg -v 'theme: fixed'
```

| 项 | 方法 | 通过条件 |
| --- | --- | --- |
| 控件跟随主题 | 用上文第 8 步的品红 palette，对九个页面各截一张临时图（不提交） | 主色位置全部为品红，没有残留的原青绿色控件 |

本阶段不新增长期保留的测试文件：默认值的正确性由像素比对证明，迁移的完整性由扫描命令证明。

## 4. P1 主题包与本机导入

### 4.1 模块

新建 `client/lib/features/theme_pack/`：

| 文件 | 职责 |
| --- | --- |
| `theme_manifest.dart` | 契约第 2 节的模型与解析，解析时同时做字段校验，出错时返回 `ThemePackError(code, field)` |
| `theme_pack_codec.dart` | 读：校验 ZIP 并解出被引用的条目，返回 manifest。写：根据 manifest 和文件表打包 |
| `theme_pack_store.dart` | 已安装主题的目录与索引；"上一个外观"的保存与恢复 |
| `theme_contrast.dart` | 对比度计算和契约第 5 节的规则检查，返回不达标的组合列表 |
| `theme_import_screen.dart` | 导入预览页 |
| `installed_themes_screen.dart` | 本机主题页 |
| `theme_section.dart` | 外观设置页中的"主题"分组 |
| `theme_presentation.dart` | 复用正式组件渲染页头模板、页头装饰；卡片参数由 `AppTheme.build` 生成 `AppCardStyle` 扩展，按契约处理窄屏、分栏和触控边界 |
| `themed_wallpaper_layer.dart` | 契约 2.9 的渲染时颜色矩阵（`ColorFilter.matrix`）、模糊与遮罩层，供壁纸、页头背景与工坊预览复用 |

### 4.2 codec

- 在 `Isolate.run` 中运行。
- 读取步骤：
  1. 检查包体是否超过 48MB；
  2. 解析 `manifest.json`，同时校验字段；
  3. 只解出 manifest 引用到的条目，累计解压量，超过 96MB 时停止；
  4. 读图片头部检查尺寸，再完整解码一次。
- 遇到第一个错误就停止，返回错误码，并删除临时目录。
- 每个读取的条目解压后调用 `ZipFile.verifyCrc32()`，返回 false 时报 `theme_zip_invalid`。`archive` 4.2.0 的 `ZipDecoder` 不会自动做这一步（它的校验代码被注释掉了）。除此之外不计算哈希。
- 模型与资源遍历必须包含 layout、cardStyle、decorations、adjustments。它们直接纳入 formatVersion 1，不保留“只解析、不渲染”的字段；未知模板及越界参数使用既有错误码。

### 4.3 本机存储

```
<应用文档目录>/themes/
├── index.json                    # 已安装列表，先写 .tmp 再 rename
├── installed/<id>/<version>/     # 解出的 manifest 与图片，按版本分目录，安装后不再改写
├── user/                         # 用户在外观设置里自选的壁纸、页头背景和贴纸
├── drafts/<draftId>/             # 工坊草稿（P2）
└── .staging/                     # 导入临时目录，App 启动时清空
```

`index.json` 中每个条目的字段：`id`、`version`（最新安装的版本）、`name`、`author`、`source`（`local`、`community`、`official`）、`familyId`、`installedAt`。

**文件清理规则**：

- `installed/<id>/<version>/` 和 `user/` 下的文件，只要还被"当前外观"或"上一个外观"引用，就保留。
- 应用主题、恢复外观、删除主题、新版本安装完成时，做一次清理：删除不被这两份配置引用、也不是 `index.json` 中最新版本的目录和文件。
- 从本机主题列表删除一个主题，只是把它从 `index.json` 中移除；它的文件按上一条规则清理。

**用户自选壁纸**：外观设置页选择壁纸时，文件统一保存到 `themes/user/<uuid>.<ext>`，不再在替换壁纸时直接删除旧文件，旧文件同样按清理规则处理。现有用户的壁纸在升级后首次启动时移入这个目录，并改写偏好中的路径。`global_background_wrapper.dart` 在壁纸旁边放了一个 `<路径>.verified` 标记文件，迁移时要和壁纸一起移动。

### 4.4 ThemeProvider

**原则**：持久化保存的是"当前外观每个分组最终生效的值"，启动时直接读取这些值，不根据主题来源重新拼装。主题 ID 和版本只作为每个分组的来源标记，用于界面展示和更新提示。

主题分为十个分组，各分组生效值的存放位置如下。font、widgets、launcherIcon 的应用逻辑在 P1.5 实现；P1 实现其余七组，并在数据结构中预留这三组。

| 分组 | 包含 | 生效值存放位置 |
| --- | --- | --- |
| `colors` | 明暗两套的种子色、方案、Token、课程色板 | `theme_appearance_v1` |
| `shape` | 圆角档位 | `theme_appearance_v1` |
| `wallpapers` | 明暗两套各四个槽位的壁纸（路径、`fit`、焦点、`blur`、`scrim`、adjustments） | `theme_appearance_v1` |
| `material` | 明暗两套各自的组件透明度、毛玻璃和 cardStyle | `theme_appearance_v1` |
| `navigation` | 底栏样式，加上五个槽位的图标和 `iconTint` | `theme_appearance_v1` |
| `layout` | 三个页头的模板、对齐和图片区尺寸 | `theme_appearance_v1` |
| `decoration` | 明暗两套的页头背景、图片效果和贴纸数组 | `theme_appearance_v1` |
| `font` | 字体名称、常规体与粗体文件路径 | `theme_appearance_v1` |
| `widgets` | 小部件是否跟随 App 主题 | 现有的小部件主题偏好 key（`widget_course_theme`、`widget_exam_theme`），取值为 `appTheme`。这是主题唯一会写入的现有 key，因为原生小部件只读这两个 key |
| `launcherIcon` | 当前内置桌面图标 ID | 由系统组件的启用状态决定，见 5.2 节；`theme_appearance_v1` 只记录来源 |

新增两个偏好 key，值都是 JSON：

- **`theme_appearance_v1`**：
  ```
  {
    colors:     { source, light, dark } | null,
    shape:      { source, value } | null,
    wallpapers: { source, light: {global, home, schedule, me}, dark: {...} } | null,
    material:   { source, light: {componentOpacity, frostedGlass, cardStyle}, dark: {...} } | null,
    navigation: { source, style, icons, iconTint, motion } | null,
    courseSettings: { source, textColor, courseColor } | null,
    layout:     { source, value } | null,
    decoration: { source, light, dark } | null,
    font:       { source, name, regular, bold } | null,
    widgets:    { source },
    launcherIcon: { source }
  }
  ```
  - `source` 的值为 `{themeId, version}`，或 null（表示默认值或用户自己设置的）。
  - `colors` 和 `shape` 为 null 时，使用 `AppPalette.defaults` 和 `standard`。
  - `wallpapers`、`material`、`navigation` 为 null 时，沿用 `ThemeProvider` 现有的偏好 key，也就是今天的行为。
  - layout、decoration 为 null 时使用现有布局、无附加装饰；cardStyle 缺省时沿用组件默认样式。
  - 不为 null 时，`ThemeProvider` 的对应 getter 返回 `theme_appearance_v1` 中的值；`material`、`wallpapers`、`decoration` 按当前生效的明暗模式（`MediaQuery.platformBrightness` 与用户的明暗设置共同决定）取 `light` 或 `dark`，系统切换明暗时立即切换。
- **`theme_previous_v1`**：上一个外观，保存十个分组的完整生效值。快照时先解析现有偏好 key 对应的壁纸、材质和底栏值，不把 null 回退引用作为快照；后续手动修改现有 key 不得改变“上一个外观”。

**主题不改写现有偏好 key**：壁纸、透明度、毛玻璃、底栏样式这些现有 key，只有用户在外观设置里手动修改时才会写入；主题的值全部存在 `theme_appearance_v1` 中。唯一的例外是 `widgets` 分组，见上表。

**规则**：

1. **应用主题**：
   1. 把当前的完整外观写入 `theme_previous_v1`；
   2. 默认勾选除桌面启动图标外的全部分组。把勾选分组的值合并进 `theme_appearance_v1`，主题未提供的分组恢复默认值，未勾选的分组保持不变。导航样式与 motion 同时应用，液态样式使用高画质、100% 强度和主题着色材质，旧手动效果不覆盖新主题；配色应用同时把 `courseSettings` 的两项设为 `theme`。`courseSettings` 仅存本机课表颜色选择，不扩展公开包格式；导出时折入最终 Token 与课程色板；
   3. 按 4.3 节的规则清理不再被引用的文件。
2. **手动修改**：
   - 用户在外观设置里改了壁纸，`wallpapers` 设为 null，回到现有的壁纸偏好，也就是用户刚设置的那张；
   - 改了毛玻璃或透明度，把新值写入现有 key，并更新 material 内对应字段、清除该组 source；保留 cardStyle 和该组其他字段；
   - 改了底栏样式：把用户选的样式写入现有 key，`navigation.style` 设为 null，图标保留。`navigation.style` 为 null 时，样式读现有 key。
   - 外观设置页的布局、卡片和装饰编辑与工坊共用参数控件；修改写入对应分组的最终值并清除 source。换页头背景时保留该页贴纸，改圆角档位时保留描边与阴影；每个分组和每个页头都有独立重置。
3. **恢复上一个外观**：先把当前外观和 `theme_previous_v1` 互换，然后清理文件。连续点两次，会回到原来的外观。
4. **恢复默认外观**：先保存 `theme_previous_v1`；然后把 `theme_appearance_v1` 中除 `widgets`、`launcherIcon` 以外的分组全部设为 null，外观回到现有 key 所记录的、用户自己设置过的值。
5. **删除主题**：只把它从 `index.json` 中移除，当前外观不变。它的文件按清理规则处理：如果还被当前外观或上一个外观引用，就会保留。
6. **升级兼容**：老用户升级后没有这两个 key，外观完全保持原样（`wallpapers` 为 null，所以沿用现有壁纸偏好）。现有壁纸文件移入 `themes/user/`，见 4.3 节。现有偏好 key 不会被删除。

**全局试用会话**：

- `ThemeProvider` 新增 `startTrial(ResolvedTheme, Set<ThemeGroup>)`、`endTrial()`、`applyTrial()`，以及 `trial` 状态。
- 试用期间，各个 getter 返回试用值，但不写入任何偏好；进程被杀后试用自然结束。
- 在 `MaterialApp.builder` 中挂一个 `ThemeTrialBanner`：试用期间在顶部安全区下方常驻显示"试用中 · 《主题名》"，带"应用"和"结束"两个按钮。
- 试用期间用户可以切换到任意页面。导入页、商城详情页、管理端审核页都调用同一个 `startTrial`。离开这些页面时不会自动结束试用。

`MaterialApp` 的 `theme` 和 `darkTheme` 改为调用 `AppTheme.build(...)`，参数取自 Provider；试用期间取试用值。

### 4.5 页面壁纸与底栏图标

- **壁纸**：
  - `global_background_wrapper.dart` 监听 `currentHomeTabIndex`，按契约 2.3 节选择槽位；
  - 槽位变化时用 `AnimatedSwitcher` 做 200ms 淡入淡出，`MediaQuery.disableAnimations` 为 true 时直接切换；
  - 解码时用 `ResizeImage` 按屏幕物理宽度解码；
  - 补上 `focal` 和 `scrim` 的渲染。
- **底栏**：
  - `LiquidBottomNav` 和 `FloatingBottomNav` 增加可选参数 `imageIcons`；
  - `template` 模式用 `ColorFiltered`（`BlendMode.srcIn`）着色；
  - 液态玻璃的着色器路径同样显示图片图标；
  - 语义标签沿用 `labels`。
- **页头与卡片**：按第 1.1 节矩阵接入 `theme_presentation.dart` 与 `AppCardStyle`（`ThemeExtension`，在 `AppTheme.build` 中计算一次）。三种页头模板复用原资料、通知和操作组件，不复制业务请求与状态管理；`AppCardStyle` 只覆盖契约规定的内容卡片。
- **图片效果与装饰**：图片效果在渲染时通过 `ColorFilter.matrix` 施加，不做解码阶段逐像素预处理；损坏图片显示资源错误提示。贴纸按契约裁切并包裹 `IgnorePointer` 与 `ExcludeSemantics` 排除命中和语义。

### 4.6 入口与页面

- **外观设置页顶部的"主题"分组**：当前主题卡片、本机主题、从文件导入、导出当前外观、恢复上一个外观、恢复默认外观。商城入口在 P4 加入，工坊入口在 P2 加入。
- **"我"页面**：新增"个性主题"入口。
- **外观设置页**：新增布局、卡片、页头装饰分组，支持与工坊相同的参数编辑、明暗切换和分组重置；无需先导出主题才能调整本机外观。
- **导入页的状态**：
  - 解析中；
  - 无效（显示提示、错误码和字段，以及"重新选择"）；
  - 需要升级（跳转到现有的更新入口）；
  - 预览（明暗切换、默认勾选除 `launcherIcon` 外全部分组，未提供组显示恢复默认说明、未提供的 `launcherIcon` 置灰、对比度警告、"试用"和"应用"）；
  - 已应用（显示 Snackbar，带"撤销"，撤销等于恢复上一个外观）。
  - 点"试用"后进入全局试用会话，可以返回去浏览其他页面；结束试用通过顶部横条操作。
- **本机主题页**：每项可以应用、导出分享、删除（删除需要二次确认）。

### 4.7 文件关联与导出

- **Android**：`MainActivity` 增加 VIEW intent-filter：
  - scheme 为 `content` 和 `file`；
  - mimeType 为 `application/vnd.sylulive.theme+zip` 和 `application/octet-stream`；
  - `pathPattern` 为 `.*\\.sltheme` 及其多级点号变体。

  收到文件后，复制到 `cacheDir/incoming-theme/`，复制量超过 48MB 就停止。然后经 `DEEPLINK_CHANNEL` 发送 `{type: "theme_file", path}`，Flutter 打开导入页。冷启动和热启动都要支持。
- **iOS**：在 `Info.plist` 中声明 `online.sylulive.theme`（后缀 `sltheme`，遵从 `public.zip-archive`）和 `CFBundleDocumentTypes`，然后由 `AppDelegate` 把文件交给同一个通道。
- **导出**：文件名为 `<主题名>.sltheme`。用 `share_plus` 分享，也可以用 `file_picker.saveFile` 保存到文件。

### 4.8 验证标准

新增两个测试文件：

**`client/test/theme_pack/theme_pack_test.dart`**：

- **codec 表格驱动**：用内存生成的包，覆盖契约第 8 节中的每个客户端错误码，再加一条合法包；其中包括"内容能正常解压，但 CRC32 被改过"的用例，期望结果为 `theme_zip_invalid`；
- **解压上限**：超过 96MB 时停止，并且临时目录被删除；
- **对比度**：黑对白为 21.0，`#777777` 对白为 4.48，结果保留两位小数；每条规则都至少有一个不达标的例子。
- **新增参数边界**：表格覆盖未知页头模板、越界尺寸、六张贴纸、非法旋转、坏装饰图及越界图片效果；合法完整包要能解析全部新增字段。
- **颜色矩阵**：验证中性参数对应单位矩阵，亮度／对比度／饱和度矩阵系数与契约 2.9 一致；纯逻辑只在本文件测一次。

**`client/test/theme_pack/theme_apply_test.dart`**：

- **Provider**（每条用例结束时都重新构造 Provider，模拟重启后再断言）：
  - 带布局、卡片、图片效果和五张贴纸的完整主题应用后重启，所有生效值及资源引用保留；只应用 B 的布局时，A 的装饰和配色不变；
  - 应用主题后手动修改透明度，不清掉卡片样式；更换页头背景，不清掉贴纸；每组重置只影响本组；
  - 保存上一个外观后再手动修改现有壁纸／材质 key，恢复仍回到快照时的真实生效值；
  - 先应用 A 的全部分组，再只应用 B 的壁纸，重启后是 A 的配色加上 B 的壁纸；
  - 应用主题后手动换壁纸，重启后壁纸是手动换的那张，配色仍是主题的；
  - A v1 更新到 v2 后，恢复上一个外观，回到 v1，并且 v1 的图片文件仍然存在；
  - 删除正在使用的主题后，外观不变；之后恢复上一个外观，仍然可以正常恢复；
  - 恢复上一个外观连续执行两次，回到原外观；
  - 恢复默认后，配置中没有残留 `themes/installed` 路径，被清理掉的版本目录确实已被删除；
  - 应用主题后，壁纸、透明度、毛玻璃、底栏样式这些现有偏好 key 的值都没有被改写；
  - 主题亮色透明度 0.9、暗色 0.75：切换平台明暗后，生效值随之切换，重启后仍然正确；
  - 试用期间不写任何偏好，重启后试用自然结束；
  - 用旧版本的偏好构造 Provider，外观保持不变，壁纸文件已移入 `themes/user/`。
- **Widget**：
  - 三个页头的三种模板、贴纸层次和卡片描边／阴影覆盖；360px 窄屏、1.5 倍字号与宽屏分栏均无溢出或操作遮挡；装饰不拦截点击和读屏；
  - 切换主题或结束试用后，装饰与壁纸随状态更新；损坏图片显示资源错误；
  - 导入页的五个状态；
  - 试用横条：试用期间切换页签时横条始终在；点"结束"后回到原外观；点"应用"后写入偏好；
  - 重复点击"应用"只执行一次；
  - 两种底栏都显示图片图标，`template` 模式的着色值正确；
  - 切换五个页签时，壁纸槽位正确，并且会回退到 `global`。

**全量检查**：`flutter analyze`；`flutter test`。

**手工验收**（中端 Android 真机）：

1. 在工坊（P2）出现之前，用测试辅助函数生成一个完整的包，写到手机上。用 QQ 把它发给自己，在 QQ 里点开，App 冷启动后直接进入预览。App 在后台时重复一次，同样直接进入预览。
2. 试用：五个页签的配色、壁纸、图标都生效，按钮、开关、滑块的颜色也跟随主题；在试用横条上点"结束"后，外观完全恢复。
3. 应用后杀掉进程再重启，主题仍然生效；点"撤销"后回到原外观。
4. 再导入第二个主题，只勾选"壁纸"并应用，重启后是第一个主题的配色加上第二个主题的壁纸。
5. 手动换一张壁纸后重启：壁纸是手动换的那张，配色仍是主题的。
6. 恢复默认外观后，界面与第 1 步之前一致。
7. 导出当前外观，在另一台设备上导入，外观一致。

**性能**（`flutter run --profile`）：

| 项 | 指标 |
| --- | --- |
| 导入 20MB 的包 | 3 秒内出现预览，UI 线程没有超过 32ms 的帧 |
| 应用主题 | 300ms 内出现新配色的首帧 |
| 带页面壁纸切换页签 | 没有超过 16ms 的 raster 帧 |

## 5. P1.5 字体、桌面图标与小部件

本阶段依赖 P1，可以和 P3 并行。三项功能分别对应 4.4 节中的 `font`、`launcherIcon`、`widgets` 三个分组。

### 5.1 自定义字体

- **注册字体**：
  - 字体用 `FontLoader` 注册，家族名为 `theme_font_<id>_<version>`。同一个家族名不能重复注册不同的字体，所以每个版本使用不同的家族名。
  - 常规体和粗体加到同一个 `FontLoader` 中，由引擎根据字体文件自带的字重信息进行匹配。
- **启动时加载**：在 `app_bootstrap.dart` 中，`runApp` 之前读取 `theme_appearance_v1.font`。有值时，读取文件、注册字体并 `await load()`，这样首帧就是主题字体，不会先闪一下默认字体。
- **切换时加载**：应用主题或开始试用时，先注册新的字体家族，再切换 `ThemeData.fontFamily`。之前注册过的字体家族会留在内存里直到进程结束，这是 `FontLoader` 的限制，不需要处理。
- **ThemeData**：
  - `fontFamily` 取主题字体的家族名，没有主题字体时为 `NotoSansCJKsc`；
  - `fontFamilyFallback` 为 `['NotoSansCJKsc', 'Noto Color Emoji', 'Segoe UI Emoji', 'Apple Color Emoji']`；
  - `lib/` 中有 2 处显式写了 `fontFamily: 'NotoSansCJKsc'`，改为不指定，让它们跟随主题；
  - `monospace` 保持不变。
- **导入校验**：codec 在 isolate 中运行，拿不到引擎，所以字体在 codec 返回之后、在主 isolate 中用一个临时家族名试加载一次。加载失败时报 `theme_font_invalid`。
- **恢复默认外观**：`font` 设为 null。

### 5.2 桌面启动图标

**Android**：

- **Manifest**：
  - 把 `MainActivity` 中 `MAIN`／`LAUNCHER` 的 intent-filter 移到新的 `<activity-alias android:name=".LauncherDefault" android:targetActivity=".MainActivity" android:icon="@mipmap/ic_launcher_main" android:enabled="true" android:exported="true">` 上。深链等其他 intent-filter 留在 `MainActivity` 上不动。
  - 契约 3.2 节中的其余每个图标，各加一个 alias（`.LauncherNight` 等），`android:enabled="false"`，图标为 `@mipmap/ic_launcher_<id>`（自适应图标：`mipmap-anydpi-v26` 中放 xml，各密度目录中放前景 PNG）。
- **升级影响**：启动入口组件由 `MainActivity` 变为 `.LauncherDefault`，在部分启动器上，用户桌面上原有的图标会在这次升级后被移除，需要从应用列表中重新拖到桌面。这是一次性的影响，写进这个版本的更新说明里。
- **内置图标清单**：新增 `BuiltinLauncherIcons.kt`，每项包含 `id`、名称、mipmap、前景 drawable，以及两个 alias 类名。未知 ID 一律按 `default` 处理。做法参照 SukiSU-Nova 的 `BuiltinAppIcons.kt`。
- **两种变体**：每个内置图标在 Manifest 中有两个 alias：
  - `.Launcher<Id>`：自适应图标带 `<monochrome>` 层，Android 13 及以上开启"主题图标"时跟随系统配色；
  - `.Launcher<Id>Static`：不带 `<monochrome>` 层，始终显示原色。
  - 用户在桌面图标页里用开关"跟随系统主题色"在两者之间选择，默认关闭。Manifest 中只有 `.LauncherDefaultStatic` 为 `enabled="true"`，与现有图标外观一致。
- **期望值存偏好，系统状态由切换逻辑对齐**：
  - 新增偏好 `launcher_icon_id_v1` 和 `launcher_icon_themed_v1`，表示用户希望使用的图标。
  - 新增 MethodChannel `app_icon`，提供 `setDesired(id, themed)`（只写这两个偏好）和 `current()`（读组件的实际启用状态）。
  - 真正切换组件的是 `applyIfNeeded()`：先确认 `MainActivity` 处于启用状态；如果目标 alias 已经启用、其他 alias 都已禁用，就什么也不做；否则先启用目标，再禁用其余，每次调用都带 `DONT_KILL_APP`。
- **只在后台切换**：在部分 ROM 上，切换正在启动或正在显示的任务所属的组件，会杀掉进程。所以 `applyIfNeeded()` 只在两个时机调用：
  1. 在 `MainActivity` 所在进程中注册 `ActivityLifecycleCallbacks`：已启动的 Activity 数降到 0、并且不是配置变更时，延迟 1 秒后再检查一次计数，仍为 0 才调用；
  2. 新增 `LauncherIconUpdateReceiver`，监听 `MY_PACKAGE_REPLACED`；App 不在前台、并且用户已解锁时调用。
  - 用户选完图标后，界面提示"返回桌面后生效，部分桌面需要几秒刷新"。
- **自定义图片快捷方式**：
  - 使用 `ShortcutManagerCompat.requestPinShortcut`，图标为 `IconCompat.createWithAdaptiveBitmap`，图片取自主题的 `launcherIcon.custom`，缩放到 432×432；
  - shortcut ID 为 `theme_<id>`，intent 直接指向 `MainActivity`（它始终处于启用状态，深链也依赖它）；
  - 小米 MIUI／HyperOS 上，请求之前先用反射调用 `AppOpsManager.checkOpNoThrow(10017, uid, pkg)` 读取"桌面快捷方式"权限：结果为 `1`（拒绝）或 `5`（询问）时，先弹窗说明，并提供跳转到本应用权限设置页的按钮；用户返回后再请求。做法参照 SukiSU-Nova 的 `Shortcut.kt`，但不使用其中的 root 授权分支；
  - `isRequestPinShortcutSupported` 返回 false 时，不显示这个入口；
  - 在 `app/build.gradle` 中显式声明 `androidx.core:core-ktx` 依赖，版本与现有 Gradle 依赖树中解析出的 `androidx.core` 一致。
- **主题应用**：应用主题时勾选了 `launcherIcon` 分组，就调用 `setDesired(builtin, 当前的 themed 设置)`，然后提示返回桌面后生效。

**iOS**：

- 把备选图标做成资源目录中的 `AppIcon-<id>.appiconset`，在 Runner target 中设置 `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES` 和 `ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS = YES`。
- `AppDelegate` 在同一个 `app_icon` 通道中实现 `setDesired(id, themed)`：忽略 `themed`，直接调用 `UIApplication.shared.setAlternateIconName`（`default` 对应 nil，系统会自动弹出提示）。iOS 允许在前台切换，所以不需要延迟。同时实现 `current()`，返回 `alternateIconName` 对应的 ID。
- iOS 不显示"添加自定义快捷方式"。

**界面**：

- 外观设置页的"主题"分组新增"桌面图标"页：用网格展示内置图标（前景图叠在圆形和圆角方形两种遮罩上预览），标出期望使用的图标；网格下方是"跟随系统主题色"开关（只在 Android 13 及以上显示）。
- 当前主题带 `custom` 图标、并且系统支持时，显示"用主题图标添加桌面快捷方式"。
- "恢复默认外观"不会改动桌面图标；桌面图标只在这个页面里修改。

### 5.3 桌面小部件跟随主题

- **Dart**：
  - `client/lib/models/home_widget_config.dart` 中的 `HomeWidgetTheme` 新增 `appTheme`（存储值为 `appTheme`，显示为"跟随 App 主题"）；小部件设置页中出现这个选项。
  - 当前生效的颜色发生变化时（应用主题、恢复外观、试用结束后应用），以及每次启动时，按契约 3.1 节换算出 `widget_app_palette_v1`（JSON，明暗两套，颜色格式为 `#AARRGGBB`），通过现有的小部件数据写入方式保存，然后触发两个小部件的更新。
  - 课表小部件数据中每门课的 `color`，改为用当前主题的 `coursePalette` 来计算。
  - 应用主题时勾选了 `widgets` 分组：把 `widget_course_theme` 和 `widget_exam_theme` 设为 `appTheme`。
- **Android**：
  - `NativeHomeWidgetTheme` 新增 `APP_THEME("appTheme")`。
  - `HomeWidgetThemeConfig.resolve` 处理 `APP_THEME` 时：从同一个 SharedPreferences 读取 `widget_app_palette_v1`，按系统的 uiMode 选择亮色或暗色；JSON 不存在时，按 `SYSTEM` 处理。
  - 背景：在 6 个根布局（课表、考试各 2x2、4x2、4x2_extra_large）中，加一个铺满的 `ImageView`（id 为 `widget_bg_tint`，src 为新增的白色圆角形状 `widget_bg_tint_shape`，圆角与现有背景一致，默认 `gone`）。
  - `APP_THEME` 时：`widget_bg_tint` 设为可见，`setInt("setColorFilter", background)`，`setInt("setImageAlpha", 开启毛玻璃时为 209，否则为 255)`，根视图的背景设为透明。其他主题时，`widget_bg_tint` 设为 gone，走现有逻辑。
- **iOS**：
  - `CourseScheduleWidget.swift` 中的十六进制颜色常量，收进一个 `WidgetPalette` 结构体。
  - 从 App Group 的 UserDefaults 读取 `widget_app_palette_v1`，按 `@Environment(\.colorScheme)` 选择亮色或暗色；没有这份数据时，使用现有的颜色常量。

### 5.4 验证标准

新增一个测试文件：`client/test/theme_pack/theme_system_test.dart`。

- **字体**：
  - 应用带字体的主题后，`ThemeData.fontFamily` 等于对应的家族名，`fontFamilyFallback` 的第一项是 `NotoSansCJKsc`；
  - 用损坏的字体字节导入，结果为 `theme_font_invalid`；
  - 恢复默认外观后，`fontFamily` 回到 `NotoSansCJKsc`。
- **小部件**：
  - 用默认 palette 和一套自定义 palette 换算出的 `widget_app_palette_v1`，逐项等于契约 3.1 节的映射；
  - 开启毛玻璃时的不透明度正确；
  - 应用主题、恢复外观之后都会写入，并触发更新；
  - 课程颜色使用主题色板。
- **桌面图标**（mock `app_icon` 通道）：
  - 应用主题时没有勾选 `launcherIcon`：不调用通道；
  - 勾选了：调用 `setDesired(id, themed)`，`themed` 保持用户当前的设置；
  - 恢复默认外观：不调用通道。

Kotlin 和 Swift 部分不新增单元测试，用下面的真机步骤验证。

**真机验收**（Android 中端机一台、小米 HyperOS 一台，iOS 一台）：

1. 从当前线上版本覆盖安装新版本，记录各台设备桌面上原有图标是保留还是被移除，写进报告和更新说明。
2. 依次选择每个内置图标，然后回到桌面：桌面显示新图标，前台使用期间 App 没有被杀；点击新图标能打开 App；`sylulive://grades`、`timetable://home` 深链和小部件点击跳转仍然正常。在 Android 13 及以上开启"跟随系统主题色"，并开启系统的主题图标，桌面图标变为单色。
2a. 选择一个非默认图标后，覆盖安装同一个新版本，安装完成后桌面图标仍是所选的那个。
3. Android：用主题图标添加桌面快捷方式，系统弹出确认，确认后快捷方式出现在桌面上，点击能打开 App。在小米 HyperOS 上先在系统设置中关闭"桌面快捷方式"权限，再操作一次：App 先弹出说明并跳转到设置页，开启权限后能成功添加。
4. 小部件选择"跟随 App 主题"，应用"海盐蓝"，课表和考试小部件的颜色更新；在系统设置中切换明暗模式，小部件跟着切换。iOS 课表小部件同样检查。
5. 应用"纸感"：九个页面的正文都是霞鹜文楷，等宽文字不变；1.5 倍字号下没有溢出；杀掉进程后冷启动，首帧就是霞鹜文楷。

**性能**（`flutter run --profile`）：带 6MB 字体的主题，冷启动到首帧的时间，比不带字体时增加不超过 150ms。

## 6. P2 主题工坊

### 6.1 页面

文件：`client/lib/features/theme_pack/theme_workshop_screen.dart`，以及 `theme_resolver.dart`（实现契约第 4 节的推导）。

- **上半屏预览**：九个首批页面均有样例，并能打开帖子／商品卡片、弹层和输入区样例；可切换明暗、正常／加载／空态／失败／权限状态。
  - 样例使用正式页面的共享组件，配上固定的假数据，不访问网络；
  - 样例放在 `theme_workshop_samples.dart` 一个文件里。
- **下半屏分十个 Tab**，窄屏横向滚动 Tab，编辑区支持键盘和读屏：

| Tab | 内容 |
| --- | --- |
| 配色 | 种子色（色盘和 HEX 输入）、方案选择、"高级"折叠区中的 Token 列表（可以逐个覆盖，也可以重置）、对比度面板（列出契约第 5 节的每一组，不达标的标红并提供"自动修正"） |
| 课表 | 色板编辑（5–12 色，可以增删）、"从种子色生成" |
| 壁纸 | 四个槽位：选图（复用现有的裁剪流程）、焦点、`blur`、`scrim`、`fit`，以及亮度、对比度、饱和度；暗色组提供"复制亮色设置"，复制后两组独立编辑 |
| 材质 | 透明度、毛玻璃、底栏样式、圆角档位；内容卡片的描边宽度和阴影档位 |
| 布局 | 首页、校园、我分别选标准／紧凑／沉浸页头，调整对齐和图片区高度、宽度 |
| 装饰 | 三个页头各自选择背景图、裁剪焦点和图片效果；最多五张贴纸，可拖动、缩放、旋转、调整前后层次、替换和删除；另有数值输入与重置入口 |
| 图标 | 五个槽位，每个两态；选图后自动居中裁成正方形，并缩放到 192px；`template`／`original` 切换 |
| 字体 | 从文件选择常规体，可选粗体；选择字体许可；预览区显示"正文 / 标题 / 数字与英文"三行样例 |
| 桌面图标 | 从内置图标中选一个（可以不选）；可选上传一张自定义图标，预览中按圆形、圆角方形两种遮罩显示 |
| 小部件 | 只读预览：按契约 3.1 节的映射，显示课表和考试小部件在亮色、暗色下的效果 |

- **起点**：可以选"当前外观"、某个已安装主题，或"默认"。
- **直接编辑**：预览点选页头／卡片后定位到对应 Tab 和参数；贴纸操作仅在工坊编辑态响应手势，实际页面不响应。拖动时先更新预览，结束后写入草稿；键盘、数值输入和读屏操作能完成同样的编辑。
- **重置与切换**：支持重置单个参数、单个页头或整个分组。切换样例、明暗和 Tab 不丢编辑值；复制亮色到暗色是一次复制，不建立隐藏联动。离开工坊遇到草稿保存失败时，保留内容并提供重试和明确放弃入口。
- **制作指南**：顶栏的"制作指南"打开一个静态页面，内容是制作细则第 1–5 节。
- **草稿**：编辑停顿 800ms 后自动保存到 `drafts/<draftId>/`。保存失败时，顶栏显示"未保存"和"重试"。
- **导出**：
  1. 用 `RepaintBoundary` 离屏渲染首页样例，亮色和暗色各一张，尺寸 1080×2340，编码为 PNG；
  2. 长边超过 2560 的壁纸，缩小后编码为 JPEG（质量 88）；
  3. 写入完整的 tokens、布局、卡片样式、图片效果和装饰资源引用，然后打包；原图保持未施加 adjustments 的状态，避免导入后重复处理；
  4. 用 codec 再解析一遍，并运行对比度检查。不达标时停留在工坊，并定位到对应的 Token。

### 6.2 验证标准

新增一个测试文件：`client/test/theme_pack/theme_workshop_test.dart`。

- **推导**：
  - 种子色 `#2F7FD8` 推导出的 `primary`、`background`、`card`、`textPrimary`、`navSelected` 五个值，在测试中写成常量断言；
  - 有覆盖值时，覆盖值优先；
  - 自动生成的色板全部达到 4.5；
  - 自动修正后达到阈值，并且色相不变。
- **导出**：导出的包能被 codec 解析；预览图尺寸为 1080×2340；超大壁纸被缩小。
- **草稿**：保存后再读取，内容一致。
- **Widget**：
  - 修改种子色后，预览跟着变化；
  - 在 360×800 视口、1.5 倍字号下，十个 Tab 的编辑内容均可访问，没有溢出；
  - 点选页头／卡片定位编辑区，贴纸拖动与数值输入改变同一组值，调整层次后预览跟随；
  - 切换样例与明暗不丢修改，复制后独立编辑，单项重置不影响同页其他贴纸；草稿保存失败保留编辑并能重试。

**手工验收**：按制作细则第 9 节的参数做出"海盐蓝"，再用同一套组件做一个沉浸页头、卡片覆盖、背景效果和五张贴纸的完整主题。导出后在另一台设备上导入，九页明暗渲染与工坊一致；试用、应用后重启、恢复上一个外观均完成；杀掉进程后草稿能恢复。参数解析和图片算法不在本文件重复测试。

## 7. P3 服务端

### 7.1 模型

`server/internal/models/theme_pack.go`，通过现有的 AutoMigrate 注册。

`ThemePack`：每一行是一次投稿，记录不可变。

| 字段 | 说明 |
| --- | --- |
| `ID` | 主键，UUID |
| `FamilyID` | 有索引；第一个版本的 FamilyID 等于自身的 ID |
| `Version` | |
| `AuthorUserID` | 有索引 |
| `Name`、`Description`、`Tags`（JSON）、`License` | |
| `Source` | `community` 或 `official` |
| `Status` | `pending`、`approved`、`rejected`、`withdrawn`、`superseded`、`removed` |
| `MinAppVersion` | |
| `FontCopyright`、`FontLicenseNote` | 带字体时，从字体 `name` 表读出的版权和许可说明，供审核页显示 |
| `PackageSHA256`、`PackageSize` | 规范包的哈希和大小 |
| `ReviewReasonCode`、`ReviewNote`、`ReviewedBy`、`ReviewedAt` | |
| `IdempotencyKey` | |
| `Downloads` | |
| `CreatedAt`、`UpdatedAt` | |

唯一索引：

- `(family_id, version)`；
- `(author_user_id, idempotency_key)`。

**作品根记录**：`ID == FamilyID` 的那一行，也就是第一个版本，是整个作品的根记录。审核、撤回、下架、投新版本，都要先 `SELECT … FOR UPDATE` 锁住根记录，再操作具体的版本。这和 `EmojiPackService.Review` 先锁 `CatalogID()` 的做法一致。

**不变式**：同一个 `FamilyID` 下，`approved` 状态的记录最多只有一条。

### 7.2 存储

```
<uploadDir>/.theme-packs/<id>/package.sltheme
<uploadDir>/.theme-packs/<id>/preview_light.jpg
<uploadDir>/.theme-packs/<id>/preview_dark.jpg
```

处理过程中使用 `.stage-<uuid>` 暂存目录，完成后 rename 成正式目录。暂存目录的启动清理复用 `EmojiPackService` 的做法。

### 7.3 服务

在 `server/internal/services/theme_pack_service.go` 中实现以下流程。校验器写在同一个包里，文件为 `theme_pack_validator.go`。

**投稿 `Submit`**：

分成锁外和锁内两段：慢的步骤放在锁外，确定 ID 和版本号并打包放在锁内，保证数据库里的版本号和包内 manifest 的版本号一致。

锁外（不开事务）：

1. 请求体上限 49MB。
2. 账号被封禁或正在注销时，返回 `theme_forbidden`。
3. 同一个用户再次提交相同的幂等键时，直接返回原来的记录。
4. 按契约做完整校验，并检查对比度规则。带字体时，用 `sfnt` 解析字体，并检查 GB2312 一级汉字的覆盖率（契约第 6 节）；同时读出字体 `name` 表中的版权（nameID 0）和许可说明（nameID 13），保存到记录上，供审核页显示。
5. 按契约第 6 节重新编码图片，写入 `.stage-<uuid>/`，同时得到改写后的图片路径。这一步与 ID、版本号无关。

锁内（一个事务）：

6. 检查配额：待审数不超过 3，24 小时内投稿不超过 5 个，否则返回 `theme_quota`。
7. 确定 ID 和版本号：
   - 新作品：生成新的 ID，`FamilyID` 等于这个 ID，`Version` 为 1。
   - 带了 `familyId`：锁住根记录；必须是本人的作品，并且根记录状态不是 `removed` 或 `withdrawn`；`Version` 设为这个版本族当前的最大版本加 1。
8. 生成最终的 manifest：
   - `id` 设为 FamilyID；
   - 写入 `version`、`author`、`source`（普通用户一律为 `community`，管理员可以指定 `official`）和图片路径；
   - 删除未知字段。
9. 在暂存目录中打包，计算一次 SHA-256，写入 `PackageSHA256`。
10. 把暂存目录 rename 成 `.theme-packs/<id>/`，然后插入记录。提交失败时，删除 rename 后的目录。

**审核 `Review`**：

- 管理员不能审核自己的投稿。
- 在事务中先锁根记录，再锁这条记录，确认它处于 `pending` 状态，否则返回 `theme_conflict`。
- **通过**：
  - 如果这个版本族当前已上架的版本号大于等于本条的版本号，返回 `theme_conflict`。按下面的取代规则，正常情况下不会出现这种情况，这里只是事务边界上的保护。
  - 本条设为 `approved`；原来的 `approved` 记录改为 `superseded`；同一版本族中版本号比本条小的 `pending` 记录，全部改为 `superseded`，并给作者发通知："已被 vN 取代"。
- **拒绝**：`reasonCode` 必须来自制作细则 8.2 节。
- 写管理员日志，并给作者发站内通知，两者都复用现有机制。

所以不论审核顺序如何，上架的版本只会前进，不会退回旧版本：

- 先通过 v3：待审的 v2 立即变成 `superseded`，之后无法再审核 v2；
- 先通过 v2：v3 仍然处于待审，之后可以审核通过。

**撤回 `Withdraw`**（先锁根记录）：

- 待审的版本：只撤回这一个版本；
- 已上架的版本：整个版本族中 `approved`、`superseded`、`pending` 的记录都改为 `withdrawn`。

**下架 `Remove`**（先锁根记录）：整个版本族的全部记录都改为 `removed`，并记录原因。

**下载计数**：在版本化的包下载接口上，请求没有 Range 头，或者 Range 从 0 开始时，`Downloads` 加 1，不做去重。计数加在根记录上。

### 7.4 接口

在 `server/cmd/theme_pack_routes.go` 中注册。错误响应统一为 `{error, code}`。

| 方法 | 路径 | 权限 | 说明 |
| --- | --- | --- | --- |
| GET | `/api/themes` | 公开 | 查询参数：`sort`（取值为 `latest`、`popular`、`official`）、`tag`、`q`、`ids`、`cursor`。每页 20 条；`popular` 按 `Downloads` 降序；`ids` 用于批量检查更新，最多 50 个；带 ETag |
| GET | `/api/themes/:familyId` | 公开 | 详情 |
| GET | `/api/themes/:familyId/versions/:version/package` | 公开 | 指定版本的规范包，支持 Range，`ETag` 为 sha256，`Cache-Control: public, no-cache`。可以下载的条件：该版本状态为 `approved` 或 `superseded`，并且根记录不是 `removed` 或 `withdrawn`。这样客户端读到 v1 的目录后，即使 v2 刚好审核通过，v1 的下载和断点续传也不受影响；一旦作品撤回或下架，带 `If-None-Match` 的请求也立即返回 404 |
| GET | `/api/themes/:familyId/versions/:version/preview/:mode` | 公开 | 预览图，可以下载的条件和缓存头同上 |
| GET | `/api/users/:id/themes` | 公开 | 作者已上架的作品 |
| POST | `/api/themes/submissions` | 登录 | multipart 表单：`package`、`idempotencyKey`，可选 `familyId`、`source` |
| GET | `/api/themes/submissions` | 登录 | 本人的投稿 |
| GET | `/api/themes/submissions/:id/package`、`/preview/:mode` | 作者或管理员 | 私有包和私有预览图 |
| POST | `/api/themes/submissions/:id/withdraw` | 作者 | 撤回 |
| GET | `/api/admin/themes?status=` | 管理员 | 审核队列，每项附带同一版本族中当前已上架版本的摘要 |
| POST | `/api/admin/themes/:id/review` | 管理员 | 请求体 `{approve, reasonCode, note}` |
| POST | `/api/admin/themes/:familyId/remove` | 管理员 | 请求体 `{reasonCode, note}` |

目录中每个条目的字段：`familyId`、`version`、`name`、`author: {id, nickname, avatarUrl}`、`tags`、`source`、`previewLight`、`previewDark`、`packageUrl`、`packageSize`、`packageSha256`、`minAppVersion`、`downloads`、`updatedAt`。

其中 `packageUrl`、预览图 URL、`packageSize`、`packageSha256` 都由同一条记录生成，指向同一个版本的不可变文件。客户端只使用目录给出的 `packageUrl`，不自己拼接地址。

**举报**：`report.go` 新增举报对象类型 `theme`，举报对象 ID 为 familyId。

### 7.5 验证标准

新增两个测试文件：

**`server/internal/services/theme_pack_service_test.go`**：

- **校验器表格驱动**：覆盖契约第 8 节中的每个错误码，测试包在内存中生成；
- **规范化**：输出中不含 `Exif`、`http://ns.adobe.com/xap` 字节串；WebP 输入被转换为其他格式；`source` 被强制设定；未知字段被删除；
- **自定义字段保留**：规范化前后 layout、cardStyle、adjustments、装饰顺序及变换值相同；背景资源路径改写后仍可定位；透明贴纸重编码后 alpha 保留；非法字段只在服务端信任边界拒绝，不静默截断为另一套外观；
- **配额**：两个上限，每个都有一条刚好通过、一条刚好超出的用例；
- **幂等**：同一个幂等键返回原记录；
- **新版本**：
  - 非作者投新版本被拒绝；
  - 版本族被下架后不能再投新版本；
  - 规范包中 manifest 的 `id` 和 `version`，等于数据库记录的 `FamilyID` 和 `Version`；
  - 两个新版本并发投稿，得到的版本号不重复、连续。
- **审核**：
  - 审核自己的投稿被拒绝；
  - 两个管理员并发审核同一个作品的 v2 和 v3（`go test -race`，然后连 PostgreSQL 再跑一次），结束后这个作品只有一条 `approved`；
  - 先通过 v3，v2 自动变成 `superseded`，再审核 v2 返回 409；
  - 先通过 v2，再通过 v3，v2 变成 `superseded`。

**`server/cmd/theme_pack_routes_test.go`**：

- 未登录投稿返回 401；
- 他人读取私有包返回 404；
- 待审的版本不出现在目录中；
- 下架后，目录、详情、包、预览图都返回 404；
- 作者撤回已上架作品后，整个版本族不可下载；
- 下载得到的字节的 SHA-256 等于 `packageSha256`；
- 读取 v1 的目录后，v2 审核通过，此时通过 v1 的 `packageUrl` 仍然能下载到 v1，并且 Range 续传结果与完整下载一致；
- 作品被下架后，所有版本的 URL 都返回 404；
- `ids` 批量查询；
- ETag 命中时返回 304。

**全量检查**：`go vet ./...`；`go test ./...`；`go build ./...`。

**隔离环境**：在一个可丢弃的 PostgreSQL 上验证首次和重复启动时的 AutoMigrate；并发审核的用例连接 PostgreSQL 再跑一次。

## 8. P4 客户端商城

### 8.1 页面

**商城首页**：

- 搜索框；
- "官方主题"横向滑动区；
- "最新 / 热门"切换，加标签筛选；
- 双列网格，卡片上有预览图、名称、作者、下载数，以及"已安装"或"可更新"角标；
- 状态：骨架屏、空状态、错误重试、加载更多、到底提示、下拉刷新。

**详情页**：

- 明暗预览图可以左右滑动、全屏查看；
- 作者行可以点击，进入 `user_home_screen`；
- 显示标签、大小、版本、许可、简介；
- 底部按钮的状态：未安装（"下载并应用"和"试用"）、下载中（进度和"取消"）、已安装但未使用（"应用"）、正在使用（"已应用"）、有新版本（"更新"）、App 版本过低（"需要更新 App"）；
- 试用：先下载并安装这个版本，然后调用 `startTrial`，进入全局试用会话（见 4.4 节），离开详情页后试用继续。安装后如果没有应用，按 4.3 节的清理规则处理；
- 菜单：分享链接、举报。

**下载**：复用 `emoji_pack_download_manager.dart` 的断点续传能力，请求目录给出的 `packageUrl`（地址中带版本号）。下载完成后核对一次 `packageSha256`，然后交给 codec 安装到 `installed/<id>/<version>/`。

**本机主题页**：用 `ids` 批量查询商城中有没有新版本。

**投稿页**：

- 进入时先运行对比度检查；
- 表单：名称、简介、标签、许可，以及"我拥有全部素材的使用权"的勾选框；
- 可以选择"作为《X》的新版本"；
- 幂等键在进入页面时生成，修改表单后重新生成；
- 提交中按钮禁用；失败时保留表单内容；`theme_quota` 对应专门的提示文案。

**我的投稿**：分为"待审核 / 已上架 / 未通过 / 已撤回"四个 Tab。未通过的项显示原因；已上架的项可以撤回。切换账号时清空列表，并丢弃迟到的旧请求结果。

**作者主页**：`user_home_screen` 新增"主题作品"分区，作者有已上架作品时才显示。

**管理端**：在 `admin_panel_screen` 中新增"主题审核"：

- 队列页；
- 审核页：明暗预览、布局／卡片／图片效果参数、全部装饰原图及层次、与上一版的对比、小部件预览、字体信息（manifest 声明的许可，以及服务端读出的 `name` 表版权和许可说明）、桌面图标（内置 ID 与自定义图片）、"试用此主题"、"通过"、"拒绝"（原因必选）。
  - "试用此主题"会下载私有包，安装为临时版本，然后调用 `startTrial` 进入全局试用会话。审核员按制作细则 8.1 节的路径跨页面检查，再通过试用横条上的"结束"回到原外观，最后返回审核页做出判定。
  - 审核页上同时显示当前是否处于试用中。
- 已上架列表：可以下架。

**深链**：

- `sylulive://theme/<familyId>`；
- `https://sylulive.online/theme/<familyId>`：加入现有的 autoVerify intent-filter，并配置 iOS Universal Links。

### 8.2 验证标准

新增一个测试文件：`client/test/theme_pack/theme_store_test.dart`。

- **Repository**：分页游标、304 时使用缓存、`ids` 批量查询；
- **下载**：哈希不一致时删除文件并报错；取消后临时文件被删除；
- **Widget**：
  - 商城页的各个状态；
  - 详情页按钮的六种状态；
  - 从详情页开始试用后返回商城首页，试用横条仍在；点"结束"后回到原外观；
  - 下载使用的是目录中的 `packageUrl`，不使用自行拼接的地址；
  - 投稿页：未勾选授权不能提交，连续点击只发一次请求，重试时用同一个幂等键；
  - 我的投稿：切换账号时丢弃旧数据；
  - 审核页：拒绝时原因必选。

**端到端手工验收**（A 为普通用户，B 为管理员，C 为另一台设备）：

1. A 在工坊做出主题并投稿；
2. B 在管理端试用后拒绝，原因选 `contrast`；
3. A 看到拒绝原因，修改后再次投稿；
4. B 审核通过；
5. C 在"最新"中下载并应用，然后打开 A 的个人主页，能看到这个作品；
6. A 发布新版本，B 审核通过，C 的本机主题页显示"可更新"，更新后生效；
7. B 下架这个主题：C 本机的副本仍可使用，商城中搜不到，分享链接打开显示"主题不存在或已下架"。

上述完整链路使用带非默认布局、卡片、图片效果和贴纸的主题；核对服务端规范包下载后的实际外观，不用只含颜色的主题替代。审核员跨页面试用、账号切换和结束试用后，装饰及旧图片任务均不得残留。

## 9. P5 官方主题（已取消预制投稿）

经维护者确认，取消程序化预制的首批官方主题投稿，商城初始不预置官方主题包，直接开放社区用户通过主题工坊制作并上传投稿。协议、服务端 `source=official` 与客户端无官方主题时自动隐藏横向专区的逻辑保持不变。

## 10. P6 移动网页

1. 在 `web/tokens.css` 中加入与契约第 3 节对应的 `--theme-<kebab-case>` 变量，默认值等于契约的默认值。
2. 在 600px 以下的布局中，把首批页面对应的网页视图的颜色迁移到这些变量上。600px 以上的桌面布局与主题落地页桌面视图不改。
3. 新增"外观 → 主题"页面：
   - 商城列表（支持游标分页加载更多，切换筛选与排序时取消旧请求）和详情（按 `id` 绑定详情状态）；
   - **应用**：
     - 用目录中的 `packageUrl` 下载规范包，使用浏览器原生 `DecompressionStream("deflate-raw")` 解压（不新增第三方依赖）；
     - 读取 manifest 中 `light`／`dark` 的 `tokens`，写到 `:root` 上；
     - 读取壁纸配置与 `adjustments`，渲染时使用 CSS `filter`（`brightness()`、`contrast()`、`saturate()`、`blur()`）施加图片效果，不使用离屏 Canvas 或逐像素预处理；移动网页布局模板与贴纸装饰推迟，参数只作用于 600px 以下的移动界面；
     - 带字体时，用 `FontFace` API 从解出的字节试加载并注册字体，校验通过后再设置 `--theme-font-family` 并写入存储。正文的 `font-family` 改为 `var(--theme-font-family, <现有字体栈>)`。刷新后同样从规范包中重新注册；
     - 桌面图标和小部件只在 App 中生效，网页端忽略；
     - 把 `{familyId, version, name, authorName, packageUrl, light, dark, font}` 的生效元数据存入 `localStorage`。图片和字体仅保存包内路径，不写入字节或临时 object URL；读写都要包在 try/catch 中。
   - **刷新后恢复**：
     1. 页面启动时，在 `<head>` 同步恢复配色 Token，避免先闪一下默认配色；
     2. 再用保存的 `packageUrl` 重新获取规范包（配合 `ETag` 与 `Cache-Control: public, no-cache`），解出壁纸与字体，生成 object URL 显示；
     3. 如果离线、缓存里也没有这个包，或字体／资源加载失败，保留配色并显示可重试的资源状态；重试时清理损坏的内存缓存并重新拉取验证；
     4. `localStorage` 读取失败时，按默认主题处理；
     5. 主题包载入时解码明暗变体的页面壁纸，站内导航复用当前主题的 object URL。新主题准备完成后一起切换配色、壁纸和字体，丢弃旧异步结果并释放旧 object URL。
     6. 恢复默认回到本浏览器首次应用的主题。已有主题且尚无初始记录的浏览器，以升级时的当前主题为基准。初始主题资源读取失败时保留当前外观，可再次恢复。
   - 规范包已经由服务端校验过，网页端不重复校验，也不实现推导。
4. 新增网站页面 `/theme/<familyId>`（经 Go 服务 `302` 跳转至 `/web/theme/<familyId>`）：显示主题详情，提供"在 App 中打开"和"在网页上应用"，主题变量仅在 `≤600px` 下生效。

**验证标准**：只新增一个测试文件 `web/e2e/theme.spec.ts`，视口 390×844。

- 应用"海盐蓝"后，首页卡片、正文、底栏的计算颜色等于主题的值，壁纸 CSS `filter` 与自定义字体生效；
- 刷新后，首帧就是主题配色（在页面加载后的第一次绘制之前读取颜色值断言），壁纸随后出现；
- 断网或字体损坏后刷新，配色仍然生效且无未捕获异常，修复或联网后重试能重新获取并恢复；
- 目录支持加载更多，切换筛选取消旧请求；详情页切换 ID 不闪现旧主题；
- 换用其他主题后恢复默认，释放替换前的 object URL，恢复首次应用主题的配色、壁纸和字体；
- 1280 宽的视口下首页与 `/web/theme/<familyId>` 落地页颜色、字体均不变。

**全量检查**：`pnpm -r check`；`pnpm test`。

## 11. 文档同步、依赖与回退

**文档同步**：

| 阶段 | 文档 |
| --- | --- |
| P0 | 回填契约第 3 节 |
| P1 | `docs/local-storage-inventory.md`：`themes/` 目录（包括 `user/` 下的自选壁纸）、`theme_appearance_v1`、`theme_previous_v1`、`cacheDir/incoming-theme/` |
| P1／P2 | 同一存储台账补齐 layout、decoration、cardStyle、图片效果和装饰原图／草稿的存储与引用清理；不新增资源哈希 |
| P1.5 | `docs/local-storage-inventory.md`：`widget_app_palette_v1`（小部件共享存储，Android SharedPreferences 与 iOS App Group）；`docs/ops/app-release.md`：在引入桌面图标 alias 的版本的更新说明中，写明"部分桌面需要重新添加图标" |
| P6 | `docs/local-storage-inventory.md`：网页端 `localStorage` 中保存的主题数据 |
| P3 | `docs/privacy-data-inventory.md`：投稿属于公开内容，服务端去除元数据 |
| P3 | `docs/retention-and-backup-inventory.md`：下架、撤回、注销时的处理 |
| P3 | `server/API.md` |
| P3 | 新建 `docs/ops/theme-packs.md`：存储、下架、商城开关、回退 |

**依赖**：P0 → P1 → P1.5、P3 可以并行 → P2（工坊需要 P1.5 的字体、桌面图标和小部件能力）→ P4 → P5 → P6。

**发布顺序**：服务端先于客户端发布。商城入口由服务端的现有功能开关控制，关闭开关只隐藏商城，本机主题功能不受影响。

**回退**：

- 关闭商城开关；
- 客户端回退到旧版本时，旧版本忽略两个主题 key，读取现有外观偏好 key。主题从不改写这些 key，所以旧版本显示的是用户最后一次在外观设置里手动设置的值，主题带来的配色、壁纸、材质都不再生效。小部件主题 key 若为 `appTheme`，旧版本不认识这个值，Dart 和 Kotlin 两端都会按"跟随系统"处理。旧版本通过 `FileImage(File(path))` 按绝对路径加载壁纸（`global_background_wrapper.dart` 第 109 行），所以迁移到 `themes/user/` 后改写过的路径同样能读到；
- 服务端先于客户端回退时，版本化的下载接口不受影响；
- 服务端的数据表保留。

## 12. 交付报告格式

```
## P<n> <阶段名>

基准：<分支> @ <开始提交> → <结束提交>

改动文件：
- <路径>：<一句话>

新增测试文件：<数量>（本阶段计划内的上限：<数量>）

检查：
| 命令或步骤 | 环境 | 结果 |

真实链路：<设备、角色、步骤、结果、截图路径>

性能：<指标：实测值 / 目标值>

未覆盖：<具体项和原因>

待确认：<具体问题，每条一句>
```
