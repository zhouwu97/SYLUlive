# 主题商城实施计划

| 文档 | 作用 |
| --- | --- |
| [ADR-005](adr/005-theme-package-and-store.md) | 产品决策 |
| [主题包格式契约](theme-pack-contract.md) | 格式、Token、推导规则、对比度规则、错误码。实现以它为准 |
| [制作与审核细则](theme-creation-guide.md) | 作者规范、审核规程、官方主题参数 |
| 本文 | 实施步骤与验证标准 |

本文写给实施者。按阶段顺序执行，每个阶段单独提交，并附第 11 节格式的交付报告。

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
- 主题工坊；
- 服务端投稿、审核、目录、下载、下架；
- 客户端主题商城；
- 首批官方主题；
- 移动网页应用主题。

**不做**：

- 鸿蒙端；
- 桌面启动图标；
- 界面文案替换；
- 付费；
- 评论；
- 桌面小部件配色；
- 自定义字体；
- 多份外观历史，只保留"上一个外观"；
- 工坊的撤销和重做。

## 2. 现状定位

| 内容 | 位置 |
| --- | --- |
| 外观偏好 | `client/lib/providers/theme_provider.dart`。偏好 key 是类内的 `_xxxKey` 常量；`minComponentOpacity` 为 0.75 |
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
| 首页 | `home_screen.dart` |
| 集市 | `market_screen.dart` |
| 课表 | `course_schedule_screen.dart`、`screens/schedule/` |
| 校园 | `campus_screen.dart` |
| 我 | `profile_screen.dart` |
| 个人主页 | `user_home_screen.dart` |
| AI 助手 | `screens/ai/` |
| 工具箱 | `toolbox_screen.dart` |
| 设置 | `settings_screen.dart`、`screens/settings/` |

**连带迁移的共享组件**：`liquid_bottom_nav.dart`、`floating_bottom_nav.dart`、`post_card.dart`、`market_post_card.dart`、`home_service_drawer.dart`、`widgets/campus/`、`widgets/settings/`、`widgets/ai/`、`widgets/course/`。

## 3. P0 语义 Token 化（外观不变）

### 3.1 步骤

1. **截取迁移前的基线。** 在迁移前的提交上，写一个临时比对测试 `client/test/theme_parity/parity_test.dart`：
   - 九个页面，视口 390×844，亮色和暗色各一张，使用 `test/helpers/` 中已有的 fixtures；
   - 运行 `flutter test test/theme_parity --update-goldens`。
   - 整个 `client/test/theme_parity/` 目录加入 `.gitignore`；P0 完成后删除这个目录，不提交。
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
   - **Token 必须同步进入 `ColorScheme`**：先用 `ColorScheme.fromSeed(seedColor, brightness, variant)` 生成颜色方案，再用 `copyWith` 把 Token 覆盖进去，对应关系如下：

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
   - `primaryColor`、`scaffoldBackgroundColor`、`canvasColor` 和分割线颜色改为从 palette 读取。
   - 默认 palette 加上默认种子色，必须得到与现在完全相同的 `ColorScheme`，由像素比对来证明。
5. **`AppThemeTokens`** 的每个 getter 改为读取 `Theme.of(context).extension<AppPalette>()!`，原有公开接口不变，并为新 Token 补充 getter。
6. **`CampusTheme`** 中的品牌、表面、文字、边框颜色改为从 palette 读取。blue、orange、green、cyan、red、dining 这几个功能识别色保持不变。
7. **课表**：`getCourseColor` 增加参数 `List<Color> palette`，调用方传入 `AppThemeTokens.of(context).coursePalette`。
8. **先做试点**：只迁移首页、设置页和 `post_card.dart`。然后在测试里临时注入一套明显不同的 palette（例如把 primary 设为品红），确认这三处的页面背景、文字、按钮、开关全部变色，没有遗漏的控件。试点通过后，再迁移其余页面。
9. **迁移页面和组件**：
   - `Color(0x…)` 字面量，以及 `AppColors` 中品牌、表面、文字、边框、输入、聊天、首页角标类的常量，替换为 Token；
   - 状态色继续使用 `AppColors`；
   - 和主题无关的纯装饰色保留原值，并在行尾加注释 `// theme: fixed`；
   - 读取 context 后不能再用 `const` 的地方，去掉 `const`。

### 3.2 验证标准

| 项 | 方法 | 通过条件 |
| --- | --- | --- |
| 外观不变 | 在迁移后运行 `flutter test test/theme_parity` | 18 张图零像素差。出现差异时修改代码，不更新基线 |
| 迁移完整 | 运行下方的扫描命令 | 先在迁移前运行一次，确认能命中已知的颜色字面量（例如 `toolbox_screen.dart`），以证明命令有效；迁移后再运行，输出为空。两次的命令和输出都写进报告 |
| 静态检查与回归 | `flutter analyze`；`flutter test --reporter compact` | 没有新增问题；全部通过 |
| 真机 | 中端 Android 机，亮暗模式下各打开九个页面一次 | 与迁移前一致 |

扫描命令如下。表达式中的 `|` 是正则的"或"，不能写成 `\|`：

```bash
cd client && rg -n -e 'Color\(0x' -e 'AppColors\.(brand|surface|text|border|composer|searchBar|message|feed)' lib/screens/home_screen.dart lib/screens/market_screen.dart lib/screens/course_schedule_screen.dart lib/screens/schedule lib/screens/campus_screen.dart lib/screens/profile_screen.dart lib/screens/user_home_screen.dart lib/screens/ai lib/screens/toolbox_screen.dart lib/screens/settings_screen.dart lib/screens/settings lib/widgets/liquid_bottom_nav.dart lib/widgets/floating_bottom_nav.dart lib/widgets/post_card.dart lib/widgets/market_post_card.dart lib/widgets/home_service_drawer.dart lib/widgets/campus lib/widgets/settings lib/widgets/ai lib/widgets/course | rg -v 'theme: fixed'
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

### 4.2 codec

- 在 `Isolate.run` 中运行。
- 读取步骤：
  1. 检查包体是否超过 20MB；
  2. 解析 `manifest.json`，同时校验字段；
  3. 只解出 manifest 引用到的条目，累计解压量，超过 64MB 时停止；
  4. 读图片头部检查尺寸，再完整解码一次。
- 遇到第一个错误就停止，返回错误码，并删除临时目录。
- 每个读取的条目解压后调用 `ZipFile.verifyCrc32()`，返回 false 时报 `theme_zip_invalid`。`archive` 4.2.0 的 `ZipDecoder` 不会自动做这一步（它的校验代码被注释掉了）。除此之外不计算哈希。

### 4.3 本机存储

```
<应用文档目录>/themes/
├── index.json                    # 已安装列表，先写 .tmp 再 rename
├── installed/<id>/<version>/     # 解出的 manifest 与图片，按版本分目录，安装后不再改写
├── user/                         # 用户在外观设置里自选的壁纸
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

主题分为五个分组，各分组生效值的存放位置如下：

| 分组 | 包含 | 生效值存放位置 |
| --- | --- | --- |
| `colors` | 明暗两套的种子色、方案、Token、课程色板 | `theme_appearance_v1` |
| `shape` | 圆角档位 | `theme_appearance_v1` |
| `wallpapers` | 明暗两套各四个槽位的壁纸（路径、`fit`、焦点、`blur`、`scrim`） | `theme_appearance_v1` |
| `material` | 组件透明度、毛玻璃 | `ThemeProvider` 现有的偏好 key。主题写入这组值时，等同于用户在毛玻璃设置里选择"自定义"并填入这两个值 |
| `navigation` | 底栏样式，加上五个槽位的图标和 `iconTint` | 底栏样式用现有偏好 key；图标和 `iconTint` 存在 `theme_appearance_v1` |

新增两个偏好 key，值都是 JSON：

- **`theme_appearance_v1`**：
  ```
  {
    colors:     { source, light, dark } | null,
    shape:      { source, value } | null,
    wallpapers: { source, light: {global, home, schedule, me}, dark: {...} } | null,
    material:   { source },
    navigation: { source, icons, iconTint }
  }
  ```
  - `source` 的值为 `{themeId, version}`，或 null（表示默认值或用户自己设置的）。
  - `colors` 和 `shape` 为 null 时，使用 `AppPalette.defaults` 和 `standard`。
  - `wallpapers` 为 null 时，沿用 `ThemeProvider` 现有的壁纸偏好，也就是今天的行为。
- **`theme_previous_v1`**：上一个外观。内容是 `theme_appearance_v1` 的完整副本，加上 `material`、`navigation`、壁纸相关的现有偏好 key 的值。

**规则**：

1. **应用主题**：
   1. 把当前的完整外观写入 `theme_previous_v1`；
   2. 把勾选分组的值合并进 `theme_appearance_v1`，`material` 和底栏样式写入现有 key；被写入分组的 `source` 设为这个主题；未勾选的分组保持不变；
   3. 按 4.3 节的规则清理不再被引用的文件。
2. **手动修改**：
   - 用户在外观设置里改了壁纸，`wallpapers` 设为 null，回到现有的壁纸偏好，也就是用户刚设置的那张；
   - 改了毛玻璃或透明度，`material.source` 设为 null；
   - 改了底栏样式，`navigation.source` 设为 null，图标保留。
3. **恢复上一个外观**：先把当前外观和 `theme_previous_v1` 互换，然后清理文件。连续点两次，会回到原来的外观。
4. **恢复默认外观**：先保存 `theme_previous_v1`；然后把 `colors`、`shape`、`wallpapers` 设为 null，清空图标，`material` 和底栏样式写回 `ThemeProvider` 的现有默认值。
5. **删除主题**：只把它从 `index.json` 中移除，当前外观不变。它的文件按清理规则处理：如果还被当前外观或上一个外观引用，就会保留。
6. **升级兼容**：老用户升级后没有这两个 key，外观完全保持原样（`wallpapers` 为 null，所以沿用现有壁纸偏好）。现有壁纸文件移入 `themes/user/`，见 4.3 节。现有偏好 key 不会被删除，因此回退到旧版本 App 后，用户看到的是升级前的外观。

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

### 4.6 入口与页面

- **外观设置页顶部的"主题"分组**：当前主题卡片、本机主题、从文件导入、导出当前外观、恢复上一个外观、恢复默认外观。商城入口在 P4 加入，工坊入口在 P2 加入。
- **"我"页面**：新增"个性主题"入口。
- **导入页的状态**：
  - 解析中；
  - 无效（显示提示、错误码和字段，以及"重新选择"）；
  - 需要升级（跳转到现有的更新入口）；
  - 预览（明暗切换、五个分组的勾选、对比度警告、"试用"和"应用"）；
  - 已应用（显示 Snackbar，带"撤销"，撤销等于恢复上一个外观）。
  - 点"试用"后进入全局试用会话，可以返回去浏览其他页面；结束试用通过顶部横条操作。
- **本机主题页**：每项可以应用、导出分享、删除（删除需要二次确认）。

### 4.7 文件关联与导出

- **Android**：`MainActivity` 增加 VIEW intent-filter：
  - scheme 为 `content` 和 `file`；
  - mimeType 为 `application/vnd.sylulive.theme+zip` 和 `application/octet-stream`；
  - `pathPattern` 为 `.*\\.sltheme` 及其多级点号变体。

  收到文件后，复制到 `cacheDir/incoming-theme/`，复制量超过 20MB 就停止。然后经 `DEEPLINK_CHANNEL` 发送 `{type: "theme_file", path}`，Flutter 打开导入页。冷启动和热启动都要支持。
- **iOS**：在 `Info.plist` 中声明 `online.sylulive.theme`（后缀 `sltheme`，遵从 `public.zip-archive`）和 `CFBundleDocumentTypes`，然后由 `AppDelegate` 把文件交给同一个通道。
- **导出**：文件名为 `<主题名>.sltheme`。用 `share_plus` 分享，也可以用 `file_picker.saveFile` 保存到文件。

### 4.8 验证标准

新增两个测试文件：

**`client/test/theme_pack/theme_pack_test.dart`**：

- **codec 表格驱动**：用内存生成的包，覆盖契约第 8 节中的每个客户端错误码，再加一条合法包；其中包括"内容能正常解压，但 CRC32 被改过"的用例，期望结果为 `theme_zip_invalid`；
- **解压上限**：超过 64MB 时停止，并且临时目录被删除；
- **对比度**：黑对白为 21.0，`#777777` 对白为 4.48，结果保留两位小数；每条规则都至少有一个不达标的例子。

**`client/test/theme_pack/theme_apply_test.dart`**：

- **Provider**（每条用例结束时都重新构造 Provider，模拟重启后再断言）：
  - 先应用 A 的全部分组，再只应用 B 的壁纸，重启后是 A 的配色加上 B 的壁纸；
  - 应用主题后手动换壁纸，重启后壁纸是手动换的那张，配色仍是主题的；
  - A v1 更新到 v2 后，恢复上一个外观，回到 v1，并且 v1 的图片文件仍然存在；
  - 删除正在使用的主题后，外观不变；之后恢复上一个外观，仍然可以正常恢复；
  - 恢复上一个外观连续执行两次，回到原外观；
  - 恢复默认后，配置中没有残留 `themes/installed` 路径，被清理掉的版本目录确实已被删除；
  - 试用期间不写任何偏好，重启后试用自然结束；
  - 用旧版本的偏好构造 Provider，外观保持不变，壁纸文件已移入 `themes/user/`。
- **Widget**：
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

## 5. P2 主题工坊

### 5.1 页面

文件：`client/lib/features/theme_pack/theme_workshop_screen.dart`，以及 `theme_resolver.dart`（实现契约第 4 节的推导）。

- **上半屏预览**：可以在"首页信息流 / 课表周视图 / 帖子卡片 / 设置列表"四个样例之间切换，并有明暗切换。
  - 样例使用正式页面的共享组件，配上固定的假数据，不访问网络；
  - 样例放在 `theme_workshop_samples.dart` 一个文件里。
- **下半屏分五个 Tab**：

| Tab | 内容 |
| --- | --- |
| 配色 | 种子色（色盘和 HEX 输入）、方案选择、"高级"折叠区中的 Token 列表（可以逐个覆盖，也可以重置）、对比度面板（列出契约第 5 节的每一组，不达标的标红并提供"自动修正"） |
| 课表 | 色板编辑（5–12 色，可以增删）、"从种子色生成" |
| 壁纸 | 四个槽位：选图（复用现有的裁剪流程）、焦点、`blur`、`scrim`、`fit`；暗色组提供"沿用亮色" |
| 材质 | 透明度、毛玻璃、底栏样式、圆角档位 |
| 图标 | 五个槽位，每个两态；选图后自动居中裁成正方形，并缩放到 192px；`template`／`original` 切换 |

- **起点**：可以选"当前外观"、某个已安装主题，或"默认"。
- **制作指南**：顶栏的"制作指南"打开一个静态页面，内容是制作细则第 1–4 节。
- **草稿**：编辑停顿 800ms 后自动保存到 `drafts/<draftId>/`。保存失败时，顶栏显示"未保存"和"重试"。
- **导出**：
  1. 用 `RepaintBoundary` 离屏渲染首页样例，亮色和暗色各一张，尺寸 1080×2340，编码为 PNG；
  2. 长边超过 2560 的壁纸，缩小后编码为 JPEG（质量 88）；
  3. 写入完整的 tokens，然后打包；
  4. 用 codec 再解析一遍，并运行对比度检查。不达标时停留在工坊，并定位到对应的 Token。

### 5.2 验证标准

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
  - 在 360×800 视口、1.5 倍字号下，五个 Tab 都没有溢出。

**手工验收**：按制作细则第 8 节的参数做出"海盐蓝"，导出后在另一台设备上导入，外观一致；杀掉进程后草稿能恢复。

## 6. P3 服务端

### 6.1 模型

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

### 6.2 存储

```
<uploadDir>/.theme-packs/<id>/package.sltheme
<uploadDir>/.theme-packs/<id>/preview_light.jpg
<uploadDir>/.theme-packs/<id>/preview_dark.jpg
```

处理过程中使用 `.stage-<uuid>` 暂存目录，完成后 rename 成正式目录。暂存目录的启动清理复用 `EmojiPackService` 的做法。

### 6.3 服务

在 `server/internal/services/theme_pack_service.go` 中实现以下流程。校验器写在同一个包里，文件为 `theme_pack_validator.go`。

**投稿 `Submit`**：

分成锁外和锁内两段：慢的步骤放在锁外，确定 ID 和版本号并打包放在锁内，保证数据库里的版本号和包内 manifest 的版本号一致。

锁外（不开事务）：

1. 请求体上限 21MB。
2. 账号被封禁或正在注销时，返回 `theme_forbidden`。
3. 同一个用户再次提交相同的幂等键时，直接返回原来的记录。
4. 按契约做完整校验，并检查对比度规则。
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
- **拒绝**：`reasonCode` 必须来自制作细则 7.2 节。
- 写管理员日志，并给作者发站内通知，两者都复用现有机制。

所以不论审核顺序如何，上架的版本只会前进，不会退回旧版本：

- 先通过 v3：待审的 v2 立即变成 `superseded`，之后无法再审核 v2；
- 先通过 v2：v3 仍然处于待审，之后可以审核通过。

**撤回 `Withdraw`**（先锁根记录）：

- 待审的版本：只撤回这一个版本；
- 已上架的版本：整个版本族中 `approved`、`superseded`、`pending` 的记录都改为 `withdrawn`。

**下架 `Remove`**（先锁根记录）：整个版本族的全部记录都改为 `removed`，并记录原因。

**下载计数**：在版本化的包下载接口上，请求没有 Range 头，或者 Range 从 0 开始时，`Downloads` 加 1，不做去重。计数加在根记录上。

### 6.4 接口

在 `server/cmd/theme_pack_routes.go` 中注册。错误响应统一为 `{error, code}`。

| 方法 | 路径 | 权限 | 说明 |
| --- | --- | --- | --- |
| GET | `/api/themes` | 公开 | 查询参数：`sort`（取值为 `latest`、`popular`、`official`）、`tag`、`q`、`ids`、`cursor`。每页 20 条；`popular` 按 `Downloads` 降序；`ids` 用于批量检查更新，最多 50 个；带 ETag |
| GET | `/api/themes/:familyId` | 公开 | 详情 |
| GET | `/api/themes/:familyId/versions/:version/package` | 公开 | 指定版本的规范包，支持 Range，`ETag` 为 sha256，`Cache-Control: public, max-age=31536000, immutable`。可以下载的条件：该版本状态为 `approved` 或 `superseded`，并且根记录不是 `removed` 或 `withdrawn`。这样客户端读到 v1 的目录后，即使 v2 刚好审核通过，v1 的下载和断点续传也不受影响 |
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

### 6.5 验证标准

新增两个测试文件：

**`server/internal/services/theme_pack_service_test.go`**：

- **校验器表格驱动**：覆盖契约第 8 节中的每个错误码，测试包在内存中生成；
- **规范化**：输出中不含 `Exif`、`http://ns.adobe.com/xap` 字节串；WebP 输入被转换为其他格式；`source` 被强制设定；未知字段被删除；
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

## 7. P4 客户端商城

### 7.1 页面

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
- 审核页：明暗预览、与上一版的对比、"试用此主题"、"通过"、"拒绝"（原因必选）。
  - "试用此主题"会下载私有包，安装为临时版本，然后调用 `startTrial` 进入全局试用会话。审核员按制作细则 7.1 节的路径跨页面检查，再通过试用横条上的"结束"回到原外观，最后返回审核页做出判定。
  - 审核页上同时显示当前是否处于试用中。
- 已上架列表：可以下架。

**深链**：

- `sylulive://theme/<familyId>`；
- `https://sylulive.online/theme/<familyId>`：加入现有的 autoVerify intent-filter，并配置 iOS Universal Links。

### 7.2 验证标准

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

## 8. P5 首批官方主题

1. 按制作细则第 8 节的参数，在工坊中做出前 5 套主题。其中"沈理青"以内置默认值为基础，只把亮色 `textSecondary` 改为 `#6E757C`。这个改动和内置默认外观不同，单独截图对比，作为有意的视觉变化验收。
2. 用维护者账号以 `official` 来源投稿，用另一个管理员账号审核通过。生产环境的操作需要维护者授权。
3. 校园四季等维护者提供照片后再制作。

通过条件：

- 5 套主题的对比度面板全部为绿；
- 九个页面明暗两套的截图，存放在 `docs/reports/<日期>-official-themes/`；
- 商城"官方主题"区按顺序显示这 5 套。

## 9. P6 移动网页

1. 在 `web/tokens.css` 中加入与契约第 3 节对应的 `--theme-<kebab-case>` 变量，默认值等于契约的默认值。
2. 在 600px 以下的布局中，把首批页面对应的网页视图的颜色迁移到这些变量上。600px 以上的桌面布局不改。
3. 新增"外观 → 主题"页面：
   - 商城列表和详情；
   - **应用**：
     - 用目录中的 `packageUrl` 下载规范包，用 `fflate` 解压；
     - 读取 manifest 中 `light`／`dark` 的 `tokens`，写到 `:root` 上；
     - 把 `{familyId, version, packageUrl, light: tokens, dark: tokens}` 存入 `localStorage`，读写都要包在 try/catch 中。这份数据只有几 KB。
   - **刷新后恢复**：
     1. 页面启动时，同步读取 `localStorage` 中的 tokens 并写到 `:root` 上，避免先闪一下默认配色；
     2. 再用保存的 `packageUrl` 重新获取规范包，解出壁纸，生成 object URL 显示。这个地址带版本号，响应头是 `immutable`，所以通常直接命中浏览器缓存；
     3. 如果离线、缓存里也没有这个包，就只显示配色，不显示壁纸；联网后重新加载，再显示壁纸。
     4. `localStorage` 读取失败时，按默认主题处理。
   - 规范包已经由服务端校验过，网页端不重复校验，也不实现推导。
4. 新增网站页面 `/theme/<familyId>`：显示主题详情，提供"在 App 中打开"和"在网页上应用"。

**验证标准**：只新增一个测试文件 `web/e2e/theme.spec.ts`，视口 390×844。

- 应用"海盐蓝"后，首页卡片、正文、底栏的计算颜色等于主题的值；
- 刷新后，首帧就是主题配色（在页面加载后的第一次绘制之前读取颜色值断言），壁纸随后出现；
- 断网后刷新，配色仍然生效；
- 恢复默认后颜色回到原值；
- 1280 宽的视口下颜色不变。

**全量检查**：`pnpm -r check`；`pnpm test`。

## 10. 文档同步、依赖与回退

**文档同步**：

| 阶段 | 文档 |
| --- | --- |
| P0 | 回填契约第 3 节 |
| P1 | `docs/local-storage-inventory.md`：`themes/` 目录（包括 `user/` 下的自选壁纸）、`theme_appearance_v1`、`theme_previous_v1`、`cacheDir/incoming-theme/` |
| P6 | `docs/local-storage-inventory.md`：网页端 `localStorage` 中保存的主题数据 |
| P3 | `docs/privacy-data-inventory.md`：投稿属于公开内容，服务端去除元数据 |
| P3 | `docs/retention-and-backup-inventory.md`：下架、撤回、注销时的处理 |
| P3 | `server/API.md` |
| P3 | 新建 `docs/ops/theme-packs.md`：存储、下架、商城开关、回退 |

**依赖**：P0 → P1 → P2 和 P3 可以并行 → P4 → P5 → P6。

**发布顺序**：服务端先于客户端发布。商城入口由服务端的现有功能开关控制，关闭开关只隐藏商城，本机主题功能不受影响。

**回退**：

- 关闭商城开关；
- 客户端回退到旧版本时，旧版本会忽略两个主题 key，读取仍然保留着的原有外观偏好 key，外观回到升级前的样子。旧版本通过 `FileImage(File(path))` 按绝对路径加载壁纸（`global_background_wrapper.dart` 第 109 行），所以迁移到 `themes/user/` 后改写过的路径同样能读到；
- 服务端先于客户端回退时，版本化的下载接口不受影响；
- 服务端的数据表保留。

## 11. 交付报告格式

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
