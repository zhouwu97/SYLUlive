# 主题包格式契约（formatVersion 1）

本文是 `.sltheme` 主题包格式的唯一定义。

- 产品决策见 [ADR-005](adr/005-theme-package-and-store.md)；
- 实施步骤见 [实施计划](theme-store-plan.md)；
- 制作与审核要求见 [制作与审核细则](theme-creation-guide.md)；
- 实现时遵守 [AGENTS.md](../../AGENTS.md) 中「实现取舍：不过度防御」一节。

## 0. 设计要点

- **manifest 写完整的颜色值。** 主题工坊导出时，把明暗两套的全部 Token 都写进 manifest。这样服务端和 Web 端直接读取颜色值即可，不需要移植配色推导逻辑；推导只在 Dart 的工坊里做（见第 4 节）。
- **默认完整应用。** App 默认选择除桌面启动图标外的所有外观分组。选中但未提供的分组恢复该组默认值，未选分组保留当前值。导航分组只应用图标与着色。试用、应用及重启保留设备的底栏样式、画质、强度和材质。经典主题和内置主题的「恢复默认外观」恢复默认液态玻璃。应用配色后课表颜色选项同步为跟随主题。系统明暗与字号独立，桌面启动图标仍需主动勾选和系统确认。
- **完整性校验。**
  - 商城目录记录规范包的 SHA-256，客户端下载完成后核对一次。
  - 包内条目逐个校验 ZIP 自带的 CRC32。`archive` 4.2.0 的 `ZipDecoder` 中对应的校验代码被注释掉了，`verify: true` 不起作用，因此要对每个读取的条目显式调用 `ZipFile.verifyCrc32()`。
  - manifest 不记录逐个资源的哈希。
- **只在一处做严格校验。** 服务端对投稿做完整校验，然后输出规范包。客户端导入本机文件时，只校验会导致崩溃或安全问题的项；导入商城下载的规范包时，只核对一次哈希。

## 1. 容器

| 项 | 规则 |
| --- | --- |
| 后缀 | `.sltheme` |
| MIME | `application/vnd.sylulive.theme+zip` |
| 封装 | 标准 ZIP（STORE 或 DEFLATE），不加密。每个读取的条目都要校验 CRC32，不一致时报 `theme_zip_invalid` |
| 条目名 | 只解出 manifest 引用到的条目，加上 `manifest.json` 本身，其余条目忽略。被引用的路径必须匹配下方的正则 |
| 大小 | 包体不超过 48MB；被引用条目的解压总量不超过 96MB，达到上限立即停止解压。不带字体的主题通常在 10MB 以内 |

manifest 中引用的路径必须匹配下面两个正则之一（`|` 是正则的"或"）：

```text
^(preview|wallpaper|icons|decorations)/[a-z0-9_-]{1,40}\.(webp|jpg|png)$
^fonts/[a-z0-9_-]{1,40}\.(ttf|otf)$
```

`decorations/` 用于第 2.8 节的页头背景图和贴纸。

## 2. `manifest.json`

UTF-8 编码，大小不超过 64KB。

### 2.1 顶层字段

| 字段 | 类型 | 必填 | 约束 |
| --- | --- | --- | --- |
| `formatVersion` | int | 是 | 等于 1 |
| `minAppVersion` | string | 是 | `MAJOR.MINOR.PATCH` 格式，与 `package_info_plus` 读到的 version 比较 |
| `id` | string | 是 | UUID。本机导出时生成，商城规范包由服务端改写为 familyId |
| `version` | int | 是 | ≥ 1。商城规范包由服务端改写 |
| `name` | string | 是 | 1–20 个字符，不能有换行 |
| `description` | string | 否 | 不超过 200 个字符 |
| `author` | string | 是 | 1–20 个字符。商城规范包由服务端改写为作者昵称 |
| `tags` | string[] | 否 | 最多 5 个，取值来自第 7 节 |
| `license` | string | 是 | `CC0-1.0`、`CC-BY-4.0`、`CC-BY-NC-4.0`、`personal-use` 之一 |
| `source` | string | 否 | 只出现在商城规范包里，取值 `community` 或 `official`。本机文件中的这个字段一律忽略 |
| `preview` | object | 是 | `{ "light": path, "dark": path }` |
| `light`、`dark` | object | 是 | 见 2.2 节 |
| `shape` | string | 否 | `compact`、`standard`（默认）、`rounded` 之一 |
| `bottomNav` | object | 否 | 见 2.4 节 |
| `font` | object | 否 | 见 2.5 节 |
| `launcherIcon` | object | 否 | 见 2.6 节 |
| `layout` | object | 否 | 同一套 UI 内的内置页头模板，见 2.7 节 |

不认识的字段：客户端直接忽略；服务端在规范化时删除。

桌面小部件的配色不在 manifest 中单独声明，由明暗变体的 Token 映射得到，见 3.1 节。

### 2.2 明暗变体（`light`、`dark` 结构相同）

| 字段 | 类型 | 必填 | 约束 |
| --- | --- | --- | --- |
| `seedColor` | string | 是 | `#RRGGBB`。作为 Material 组件 `ColorScheme.fromSeed` 的输入 |
| `schemeVariant` | string | 否 | `tonalSpot`（默认）、`neutral`、`vibrant`、`expressive`、`fidelity`、`content` 之一 |
| `tokens` | object | 是 | 第 3 节的全部 Token 都要给出。值为 `#RRGGBB`；标注了"可透明"的 Token 也可以用 `#AARRGGBB` |
| `coursePalette` | string[] | 是 | 5–12 个 `#RRGGBB` |
| `wallpapers` | object | 否 | 键为 `global`、`home`、`schedule`、`me`、`secondary`，值为壁纸对象或 null |
| `componentOpacity` | number | 否 | 0–1.0，默认 1.0。百分比直接对应卡片底色不透明度；明暗两套分别生效，系统切换明暗时随之切换。低于 0.75 的主题包需将 `minAppVersion` 设为支持该范围的客户端版本 |
| `frostedGlass` | object | 否 | `{ "enabled": bool, "strength": 0–1 }` |
| `cardStyle` | object | 否 | 共享卡片样式，见 2.7 节；省略时保留当前组件默认样式 |
| `decorations` | object | 否 | 三个页头的背景图与贴纸，见 2.8 节；明暗分别生效 |

### 2.3 壁纸对象

| 字段 | 必填 | 约束 |
| --- | --- | --- |
| `portrait` | 是 | `wallpaper/` 下的路径 |
| `landscape` | 否 | `wallpaper/` 下的路径；缺省时横屏也用 `portrait` |
| `fit` | 否 | `cover`（默认）或 `contain` |
| `focalX`、`focalY` | 否 | 0–1，默认 0.5 |
| `blur` | 否 | 0–20，默认 0 |
| `scrim` | 否 | 0–0.6，默认 0。在壁纸上叠加一层 `background` 色，这是它的不透明度 |
| `adjustments` | 否 | 静态图片效果，见 2.9 节 |

页签与壁纸槽位的对应关系：

| 页签 | 使用的槽位 |
| --- | --- |
| 首页 | `home` |
| 课表 | `schedule` |
| 我 | `me` |
| 集市、校园 | `global` |
| 二级页面（工具箱、设置、详情页等从主壳打开的页面） | `secondary` |

页面槽位为空时，回退到 `global`；`global` 也为空时，显示 `background` 纯色。

### 2.4 `bottomNav`

| 字段 | 约束 |
| --- | --- |
| `style` | `normal`、`floating`、`liquid_glass` 之一。兼容旧包，客户端忽略其值，工坊导出和服务端新规范包省略此字段。旧客户端按自己的缺省规则应用液态玻璃 |
| `iconTint` | `template`（默认）或 `original`。`template` 模式只取图标的 alpha 通道，再按 `navSelected` 或 `navUnselected` 着色 |
| `icons` | 键为 `home`、`market`、`schedule`、`campus`、`me`，值为 `{ "normal": path, "selected": path }` 或 null。每个槽位的两态必须同时给出 |

### 2.5 `font`

| 字段 | 必填 | 约束 |
| --- | --- | --- |
| `name` | 是 | 字体的显示名称，1–30 个字符，例如"霞鹜文楷" |
| `regular` | 是 | `fonts/` 下的路径。TTF 或 OTF，单个文件不超过 24MB，不能是字体集合（TTC） |
| `bold` | 否 | `fonts/` 下的路径，约束同上。缺省时，粗体由引擎合成 |
| `license` | 是 | `OFL-1.1`、`Apache-2.0`、`CC0-1.0`、`author-owned` 之一。`author-owned` 表示作者本人拥有字体版权 |

适用范围：

- 字体只替换 App 正文所用的字体（`ThemeData.fontFamily`）。
- 等宽字体（代码、日志等处显式写着 `fontFamily: 'monospace'` 的地方）不受影响。
- 字号和文字缩放仍由用户的字号设置决定，主题不改变它们。
- 字体里缺少的字形，按顺序回退到内置的 `NotoSansCJKsc` 和表情字体。
- 桌面小部件不使用主题字体：Android 的 RemoteViews 不能加载 App 私有目录中的字体文件。

### 2.6 `launcherIcon`

| 字段 | 必填 | 约束 |
| --- | --- | --- |
| `builtin` | 否 | 内置备选图标的 ID，取值来自第 3.2 节的表格 |
| `custom` | 否 | `icons/` 下的路径，正方形 PNG 或 WebP，边长 432–1024，必须完全不透明 |

两者至少给出一个。

- **`builtin`**：替换系统桌面上 App 本身的图标。Android 和 iOS 都只能切换到随安装包一起打包的图标，所以只能从内置列表中选择。
- **`custom`**：在 Android 上以"添加桌面快捷方式"的方式使用。系统会弹窗请用户确认，然后在桌面上多出一个使用这张图片的快捷方式，原来的 App 图标仍然保留。大部分启动器会在这类快捷方式的角上叠加一个小的 App 图标。iOS 没有对应的能力，所以 iOS 上不显示这个选项。

### 2.7 单套 UI 的布局与卡片样式

下列字段选择同一套组件内的模板与参数，不携带组件树。选中对应分组而省略整个对象时，使用默认布局和组件样式；取消勾选该组时保留当前值。

顶层 `layout`：

| 字段 | 约束 |
| --- | --- |
| `home`、`campus`、`me` | 各为页头模板对象，可省略；对应首页、校园、我，不改变列表排序、页签、功能入口和权限 |

页头模板对象：

| 字段 | 约束 |
| --- | --- |
| `preset` | `standard`（默认）、`compact`、`immersive`。当前明暗模式有背景或贴纸时使用沉浸页头；无装饰时 compact 使用紧凑信息区，其余使用标准信息区 |
| `alignment` | `start`（默认）、`center`、`end`，只控制页头标识与摘要的水平对齐 |
| `imageHeight` | 96–280，默认 150，单位 dp，表示沉浸页头的预留高度。已规范化的旧包沿用其中记录的高度 |
| `imageWidth` | 0.45–1.0，默认 1.0，旧字段，仅供兼容读取。手机 hero 整宽，平板 hero 填满所属内容栏 |

**immersive（沉浸页头）**：在主壳的首页、校园、我三个页签里，页头背景图作为 hero 画在页面背景层中，从屏幕顶部（状态栏下方）铺到内容区锚点下方 28dp，顶栏、搜索框、页头信息和第一张内容卡都叠在 hero 上。hero 顶部用 `background` 色从 62% 透明度渐变到 0，保证顶栏文字清楚；底部最后 18% 渐隐到 `background`。首页不再显示单独的信息卡，标题直接叠在 hero 上；校园、我的信息卡上压 hero 底边。滚动时 hero 以内容一半的速度上移，校园和我滚过 hero 高度 70% 时完全淡出，首页在吸顶控件背后保留一段 hero。贴纸坐标按 hero 区域换算。主题设置实时预览、全屏样例、导入应用效果、工坊及 1080×2340 明暗导出共用沉浸绘制。预览顶栏与搜索框叠在 hero 上，校园和我的信息卡压住底边，同时显示主题底栏图标、首页顶栏图标和发帖按钮角饰。二级页面及页头素材编辑器沿用内嵌装饰区。`imageWidth` 对 immersive 不生效，hero 始终整宽。

明暗共用布局，装饰分别判断。无装饰时信息区自然排版。有装饰的槽位导出为 immersive；若只有一个明暗变体有装饰且作者显式选择 compact，导出保留 compact 供另一模式使用。信息区依内容和系统文字缩放自然增长，图片区尺寸不能限制资料、通知、按钮的高度。平板侧栏下，hero 从所属内容栏顶部铺到锚点下方，沿用手机渐隐规则，在内容栏边界裁切。

明暗变体的 `cardStyle`（圆角统一由顶层 `shape` 档位控制，不在 `cardStyle` 中重复声明）：

| 字段 | 约束 |
| --- | --- |
| `borderWidth` | 0–2，单位 dp；颜色只读取 cardBorder；省略时沿用组件默认描边 |
| `shadow` | `none`、`soft`、`medium`；省略时沿用组件默认阴影。soft 为黑色 8%／12%（亮／暗），offset (0,2)、blur 8；medium 为黑色 12%／18%，offset (0,4)、blur 16；spread 均为 0 |

作用对象是首批范围中的共享内容卡片、帖子卡片、商品卡片和 AI 内容卡片。课程色块、输入控件、弹层、系统控件及用户图片不套用这组卡片几何参数；它们仍读取各自的 Token 和 AppShape。componentOpacity 只影响容器底面，不给文字、商品照片、头像和操作按钮整体加透明度。

平板分栏课表在课表区域绘制 `schedule` 壁纸，横屏优先使用 `landscape`。今日概览和周网格之间与外缘留出壁纸区域。今日概览与周网格容器使用 `componentOpacity`、`frostedGlass`、`cardStyle` 和 `cardArt`。概览内的课程色块使用 `coursePalette` 和 `courseCardText`。

### 2.8 页头装饰

明暗变体的 `decorations` 可包含 `home`、`campus`、`me` 三个键，每个值是下列对象或 null：

| 字段 | 约束 |
| --- | --- |
| `background` | 可省略；`{image, fit, focalX, focalY, blur, scrim, adjustments}`。image 为 decorations/ 下的图片路径；其余字段与壁纸对象同义 |
| `stickers` | 最多 5 项，默认空数组，每项结构见下表 |

贴纸对象：

| 字段 | 约束 |
| --- | --- |
| `image` | decorations/ 下的 PNG 或 WebP，允许透明 |
| `x`、`y` | 0–1，贴纸中心相对 hero 或内嵌装饰区的坐标 |
| `width` | 0.08–0.40，占装饰区宽度的比例；保持图片比例 |
| `rotation` | -180–180，单位度，默认 0，顺时针为正 |

image、x、y、width 必填；rotation 可省略。数值字段只接受有限数，不能使用 NaN 或无穷值。

手机和平板主壳、页面样例、导入应用效果、工坊和导出共用沉浸页头绘制。页头素材编辑器和二级页面仍使用内嵌装饰区。平板校园按栏宽增加 hero 高度，背景维持原焦点。无装饰时不预留图片区。背景、贴纸均裁切到所在区域，贴纸按数组顺序从后向前绘制。它们不进入语义树、不响应点击，绘制在页头信息、真实个人资料、功能入口、系统状态栏和全局试用横条下方。校园和我的页头信息区使用不透明的 card 底面与 textPrimary／textSecondary。

装饰仅属于当前设备外观，不上传为个人资料，不改写用户主页已有封面，也不覆盖其他作者的头像、封面和内容图片。九个页面共用配色与组件风格；装饰槽位仅出现在上述三个页头。

### 2.9 静态图片效果

壁纸和页头背景的 `adjustments` 使用同一结构；不应用于贴纸、图标、头像、商品图或用户上传的正文图片。

| 字段 | 范围 | 默认值 |
| --- | --- | --- |
| `brightness` | -100–100 | 0 |
| `contrast` | 0–200 | 100 |
| `saturation` | 0–200 | 100 |

渲染方式：渲染时使用颜色矩阵（Flutter 用 `ColorFilter.matrix`，网页用 CSS `filter`），不在图片解码阶段做逐像素预处理或离屏 Canvas 烘焙，随后叠加 `blur` 与 `scrim`：

- 亮度、对比度、饱和度按 sRGB 线性颜色矩阵组合（亮度偏移 `brightness / 100`，对比度系数 `contrast / 100`，饱和度按亮度权重 `0.2126R + 0.7152G + 0.0722B` 插值 `saturation / 100`，alpha 保持不变）；网页端对应 `brightness()`、`contrast()`、`saturate()`。
- 工坊预览、实际页面和导出预览复用同一渲染矩阵；明暗两套参数独立保存。服务端只规范化原图并保留这些参数，不把效果烘焙进图片后再次应用。

本次字段纳入尚未交付的 formatVersion 1；带上述字段的包由 P1 实现确定并填写 minAppVersion。以后不能把同名字段改成另一种含义。已知模板、枚举或数字字段不合法，统一报 theme_field_invalid 并带字段路径；缺图和坏图分别使用既有 theme_asset_missing、theme_image_invalid。

### 2.10 视觉 V2 扩展（全部可选）

以下字段来自[主题视觉改版方案](theme-visual-redesign.md)。省略时外观与之前完全一致。

明暗变体中新增：

| 字段 | 约束 | 作用 |
| --- | --- | --- |
| `identityHarmony` | 0–1 | 分类图标、集市橙等板块识别色在 HCT 空间向 `primary` 色相靠拢：旋转 `min(色相差×0.6, 40°)×强度`，色度乘 `1−0.35×强度`，色调不变。状态色（成功、警告、危险、金额）不受影响 |
| `backdrop` | 见下表，至少一项 | 氛围背景。没有壁纸图片的页面显示它；页面因此保持透明，但顶栏文字仍按"无壁纸"取色 |
| `cardStyle.fill` | `solid`、`tint`、`glass` | `tint`／`glass` 把默认卡片底色向 `primaryContainer` 混合 32%；显式指定底色的卡片不变 |
| `sectionMark` | `{style: none／dot／bar／icon, image}`；icon 必须带 `decorations/` 下的透明图 | 区块标题前的主题记号，按 `primary` 着色 |
| `illustrations` | `{empty, error}`，`decorations/` 下透明 PNG／WebP，长边 ≤ 1024，≤ 1MB | 共享空状态、错误状态在图标位置显示插画；加载态不替换 |
| `ornaments` | 键为 `postCard`、`campusHeader`、`campusNotice`、`campusServices`、`fab`，值见下表 | 角饰：首页信息流帖子卡片、校园页头信息卡、校园通知卡、校园服务宫格、首页发帖按钮。`fab` 的坐标以 52×52 的圆形按钮为基准，通常用负 `dy` 让角色趴在按钮上沿；只在手机底栏布局的首页出现，旧版 App 会忽略这个键 |
| `cardArt` | `{image, alignment, width, opacity}`：image 为 `decorations/` 下透明插画（插画限制）；alignment 取 `bottomRight`（默认）、`bottomLeft`、`topRight`、`topLeft`；width 0.2–0.7，占卡片宽度的比例，默认 0.42，最宽 200 逻辑像素；opacity 0.04–0.4，默认 0.14 | 内容卡片（帖子、评论区、说明卡、表单卡等）里的淡底图，画在内容后面并按卡片圆角裁切；胶囊、圆形、弹窗面板和过小的卡片不画 |
| `serviceIcons` | 键为 `edu`、`canteen`、`ranking`、`team`、`map`、`calendar`（校园服务）和 `erke`、`fitness`、`exam`、`papers`、`sites`、`cloudGame`、`lottery`（工具箱），以及 `menu`、`messages`、`search`（首页顶栏的菜单、消息按钮和搜索框图标），值为 `icons/` 下透明方图（图标限制） | 替换入口图标：服务与工具按 40×40 显示，不再叠加识别色底板；顶栏菜单 26、消息 25、搜索 22 逻辑像素，按原图颜色显示，未读红点仍由 App 绘制。没给的键保持原图标，旧版 App 忽略新增的键 |

角饰对象：

| 字段 | 约束 |
| --- | --- |
| `image` | `decorations/` 下透明 PNG／WebP（贴纸限制） |
| `corner` | `topLeft`、`topRight`、`bottomLeft`、`bottomRight`，默认 `topRight` |
| `width` | 24–160，显示宽度（逻辑像素），高度按图片比例 |
| `dx` | -64–240，从所选角向卡片内侧的水平偏移，默认 0 |
| `dy` | -96–96，向卡片内侧为正，负值表示探出卡片边缘，默认 0 |
| `opacity` | 0–1，默认 1 |

角饰不占布局、不响应点击、不进语义树，画在卡片之上，制作时要避开卡片右上角的「更多」按钮和文字。

`backdrop`：

| 字段 | 约束 |
| --- | --- |
| `gradient` | `{colors: 2–4 个 #RRGGBB, angle: 0–360，默认 180}`；角度按 CSS 语义，180 为自上而下 |
| `glow` | 最多 3 项 `{color, x: 0–1, y: 0–1, radius: 0.1–1.5（默认 0.5）, opacity: 0–1（默认 0.6）}`，径向光斑 |
| `pattern` | `{tile: decorations/ 下透明图（贴纸限制）, opacity: 0–1（默认 0.2）, scale: 0.5–2（默认 1）}`；scale 1 时一个纹理块按 256 逻辑像素平铺 |

顶层 `font` 新增可选的 `title: {name, regular, license}`：标题字体只作用于 16 号及以上的展示文字（页头标题、区块标题、`TextTheme` 的 display／headline／titleLarge），小字号保持正文字体。`font` 可以只提供 `title` 而不提供正文字体。

## 3. 语义 Token

下表中写着"P0 回填"的项，取 P0 迁移时代码中的实际值；回填完成后，本表就是默认外观（沈理青）的唯一来源。

| Token | 用途 | 默认亮色 | 默认暗色 | 可透明 |
| --- | --- | --- | --- | --- |
| `primary` | 主强调色、选中态 | `#147C72` | `#7ED6C5` | |
| `onPrimary` | 主强调色上的内容 | `#FFFFFF` | `#0F2622` | |
| `primaryContainer` | 弱强调表面 | `#EAF6F3` | `#162B28` | |
| `onPrimaryContainer` | 弱强调表面上的内容 | `#0F635B` | `#7ED6C5` | |
| `background` | 页面底色 | `#FFFAF4` | `#111315` | |
| `surface` | 次级表面 | `#FFFFFF` | `#1A1D1F` | |
| `surfaceElevated` | 浮层、弹窗 | `#FFFFFF` | `#232729` | |
| `surfaceMuted` | 弱化表面 | `#F2F3F1` | `#24282A` | |
| `card` | 卡片 | `#FFFFFF` | `#1A1D1F` | |
| `cardBorder` | 卡片描边 | `#E2EFEA` | `#303638` | ✓ |
| `textPrimary` | 正文 | `#1F2328` | `#F2F4F3` | |
| `textSecondary` | 次要文字 | `#747B82` | `#A7AFAB` | |
| `textTertiary` | 辅助文字 | `#9AA1A1` | `#8E9894` | |
| `textDisabled` | 禁用文字 | `#B8BDBA` | `#5A615D` | |
| `divider` | 分割线 | `#E8EEE9` | `#252A2C` | ✓ |
| `outline` | 控件描边 | `#E2EFEA` | `#303638` | ✓ |
| `inputFill` | 输入框 | `#F2F3F1` | `#24282A` | |
| `inputFillFocused` | 输入框（聚焦） | `#EFF4F1` | `#2B3033` | |
| `searchFill` | 搜索框 | `#F1F2F0` | `#24282A` | |
| `tagBackground` | 标签底色 | `#EEF2F0` | `#282D30` | |
| `tagText` | 标签文字 | `#147C72` | `#90D5C7` | |
| `navBackground` | 底栏与侧栏 | `#9EEDF0F5` | `#B8252A32` | ✓ |
| `navSelected` | 底栏选中项 | `#1765DA` | `#84BAFF` | |
| `navUnselected` | 底栏未选中项 | `#4B525E` | `#D1D5DB` | |
| `appBarBackground` | 顶栏 | `#F4FBF8` | `#0E1513` | ✓ |
| `appBarForeground` | 顶栏内容 | `#161D1C` | `#DDE4E1` | |
| `bubbleIncoming` | 收到的消息气泡 | `#F0F1EF` | `#262A2C` | |
| `bubbleIncomingText` | 收到的消息文字 | `#1F2328` | `#F2F4F3` | |
| `bubbleOutgoing` | 发出的消息气泡 | `#76C4FF` | `#80C4FC` | |
| `bubbleOutgoingText` | 发出的消息文字 | `#1F2328` | `#111315` | |
| `feedSectionSurface` | 首页版块角标 | `#E8F5F1` | `#162B28` | |
| `feedFeaturedSurface` | 精华角标底色 | `#FFF3E0` | `#3A2A18` | |
| `feedFeaturedText` | 精华角标文字 | `#D97706` | `#F2B15A` | |
| `courseCardText` | 本周课程卡片文字 | `#FFFFFF` | `#FFFFFF` | |
| `timetableGrid` | 课表网格线 | `#0D000000` | `#33FFFFFF` | ✓ |
| `timetableToday` | 课表"今天"列 | `#00000000` | `#00000000` | ✓ |

默认值来源：`textDisabled` 取禁用文字色；顶栏取默认 `ColorScheme` 的 `surface` 与 `onSurface`；`feedSectionSurface` 暗色取 `brandSurfaceDark`。导航取液态底栏的选中、未选中文字和非着色器表面，表面 alpha 分别为 0.62、0.72。课表网格取横线（亮色为简洁模式），没有“今天”列底色，取透明。

**默认值与对比度规则的关系**：默认的 `textSecondary` 亮色值 `#747B82`，在 `card`（`#FFFFFF`）上的对比度为 4.29，在 `background`（`#FFFAF4`）上为 4.13；默认的 `tagText` 亮色值 `#147C72` 在 `tagBackground`（`#EEF2F0`）上的对比度为 4.47，均达不到第 5 节要求的 4.5。

- 内置默认外观保留既有显示效果。本周课程卡片沿用白字，默认外观不经过商城的对比度检查。
- 官方主题"沈理青"把亮色 `textSecondary` 改为 `#6E757C`（在 `card` 上为 4.67，在 `background` 上为 4.5），亮色 `tagText` 改为 `#107A70`（原值对比度 4.47）。

**默认课程色板**：`#448AFF`、`#00C853`、`#9C27B0`、`#FF5252`、`#FF9800`，即 `courseColors` 的现值。课程卡片的颜色等于 `色板[hash % 长度]` 以 0.45 的不透明度显示，这个规则保持不变。

**主题不能修改的颜色**：

- 状态色（success、warning、danger、info）；
- 头像和图片占位色。

### 3.1 桌面小部件颜色映射

小部件选择"跟随 App 主题"时，App 会把当前生效的 Token 按下表换算成小部件的颜色，写入小部件的共享存储。小部件按系统的明暗模式，在亮色和暗色两套颜色之间选择。

| 小部件颜色 | 来源 Token |
| --- | --- |
| `background` | `card` |
| `primaryText` | `textPrimary` |
| `secondaryText` | `textSecondary` |
| `mutedText` | `textTertiary` |
| `accent` | `primary` |
| `divider` | `divider` |

- 小部件开启了毛玻璃时，`background` 以 0.82 的不透明度绘制；没有开启时，完全不透明。
- 课表小部件中每门课的颜色，与 App 课表使用同一个 `coursePalette` 和同一套取色规则。

### 3.2 内置备选桌面图标

| ID | 名称 | 对应官方主题 |
| --- | --- | --- |
| `default` | 沈理青 | 沈理青（即当前的 `ic_launcher_main`） |
| `night` | 墨夜 | 墨夜 |
| `sea` | 海盐蓝 | 海盐蓝 |
| `sakura` | 樱粉 | 樱粉 |
| `paper` | 纸感 | 纸感 |
| `campus` | 校园四季 | 校园四季 |

图标图片由维护者提供，随安装包发布。每个图标要提供三张图：前景、背景色，以及单色剪影（用于 Android 13 及以上的"主题图标"）。新增备选图标需要发布新版本 App，同时在本表中追加一行，已有 ID 不能改名。

## 4. 工坊推导规则（只在 Dart 中实现）

工坊根据种子色生成全部 Token，作者可以逐个覆盖；导出时把最终值全部写入 manifest。服务端和 Web 端不实现本节。

**Token 推导**：调用 `ColorScheme.fromSeed(seedColor, brightness, dynamicSchemeVariant)`，按下表取对应角色。"合成"指用 `Color.alphaBlend` 叠到 `background` 上，得到一个不透明的颜色。

| Token | 来源 |
| --- | --- |
| `primary`、`onPrimary`、`primaryContainer`、`onPrimaryContainer` | 同名角色 |
| `background`、`appBarBackground` | `surface` |
| `surface` | `surfaceContainerLow` |
| `surfaceElevated` | 亮色用 `surfaceContainerLowest`，暗色用 `surfaceContainerHigh` |
| `surfaceMuted`、`inputFill`、`searchFill` | `surfaceContainerHighest` |
| `inputFillFocused`、`bubbleIncoming` | `surfaceContainerHigh` |
| `card` | 亮色用 `surfaceContainerLowest`，暗色用 `surfaceContainer` |
| `cardBorder`、`divider`、`timetableGrid` | `outlineVariant` |
| `outline` | `outline` |
| `textPrimary`、`bubbleIncomingText`、`appBarForeground` | `onSurface` |
| `courseCardText` | 固定 `#FFFFFF`，与内置默认外观一致 |
| `textSecondary`、`navUnselected` | `onSurfaceVariant` |
| `textTertiary` | `onSurfaceVariant` 以 75% 不透明度合成 |
| `textDisabled` | `onSurface` 以 38% 不透明度合成 |
| `tagBackground`、`feedSectionSurface` | `secondaryContainer` |
| `tagText` | `onSecondaryContainer` |
| `navBackground` | `surfaceContainer` |
| `navSelected` | `primary` |
| `bubbleOutgoing` | `primaryContainer` |
| `bubbleOutgoingText` | `onPrimaryContainer` |
| `feedFeaturedSurface` | `tertiaryContainer` |
| `feedFeaturedText` | `onTertiaryContainer` |
| `timetableToday` | `primary` 以 12% 不透明度合成 |

**课程色板生成**：「从种子色生成」从种子色相起每 60° 取一色，共 6 色，色度 52，色调亮色 56、暗色 60，配白色课程文字；「恢复原版课程色」给出原版 UI 的五色 `#448AFF`、`#00C853`、`#9C27B0`、`#FF5252`、`#FF9800`。作者可以逐个改色，主题包应提供与插画配色协调的色板。

**对比度计算**：按 WCAG 2.1 计算对比度。带透明度的颜色，先合成到它实际所在的背景上再计算。

**自动修正**：保持 HCT 的色相和色度不变，每次把色调朝提高对比度的方向移动 1，直到达到阈值；调到 0 或 100 仍然不达标，就不再修正，在面板上保留红色标记。

## 5. 对比度规则

明暗两套都要检查：

| 前景 | 背景 | 阈值 |
| --- | --- | --- |
| `textPrimary` | `background`、`card` | 4.5 |
| `textSecondary` | `card` | 4.5 |
| `onPrimary` | `primary` | 4.5 |
| `tagText` | `tagBackground` | 4.5 |
| `appBarForeground` | `appBarBackground` | 4.5 |
| `bubbleOutgoingText` | `bubbleOutgoing` | 4.5 |
| `navSelected`、`navUnselected` | `navBackground` | 3.0 |

课程块文字与色板不参与硬性对比度检查：课程块按用户设置的不透明度叠在课表背景上，白字配原版五色与内置默认外观一致。

不达标时，各处的处理：

| 场景 | 处理 |
| --- | --- |
| 工坊 | 标红，并提供"自动修正" |
| 本机导入 | 显示警告，仍然允许应用 |
| 商城投稿 | 服务端拒绝 |

## 6. 图片与字体

| 用途 | 格式 | 尺寸 | 单张上限 |
| --- | --- | --- | --- |
| 壁纸 | WebP、JPEG、PNG | 长边不超过 4096 | 8MB |
| 图标 | WebP、PNG | 正方形，边长 48–256 | 256KB |
| 预览图 | WebP、JPEG、PNG | 1080×2340 | 2MB |
| 自定义桌面图标 | WebP、PNG | 正方形，边长 432–1024，不能有透明像素 | 1MB |
| 页头背景 | WebP、JPEG、PNG | 投稿长边 1200–2048，本机导入保留 2048 上限 | 2MB |
| 装饰贴纸 | WebP、PNG | 长边不超过 1024 | 512KB |

**字体文件**：

- 客户端：用 `FontLoader` 加载，加载失败时报 `theme_font_invalid`。
- 服务端：
  - 用 `golang.org/x/image/font/sfnt`（`x/image` 已经是现有依赖）解析，解析失败时报 `theme_font_invalid`；
  - 检查字形覆盖：可打印 ASCII 全部覆盖，GB2312 一级汉字（3755 个）至少覆盖 99%，否则报 `theme_font_coverage_low`。一级汉字列表用 `golang.org/x/text/encoding/simplifiedchinese` 解码 GB2312 的 0xB0A1–0xD7F9 区间得到，`x/text` 已经是现有的间接依赖，改为直接依赖；
  - 字体文件不重新编码，原样放进规范包。

**尺寸检查**：先只读取图片头部拿到尺寸，超出限制就直接拒绝，不做完整解码。Dart 端用 `ui.ImageDescriptor`，Go 端用 `image.DecodeConfig`。

**服务端规范化**：

- 重新编码全部图片，同时去掉元数据：壁纸、页头背景和预览图编码为 JPEG（质量 88），图标和贴纸编码为 PNG，保留贴纸透明度；
- 同步改写 manifest 中的路径；
- 规范包内不含 WebP。

## 7. 标签

`浅色`、`深色`、`明暗自适应`、`简约`、`清新`、`可爱`、`动漫`、`风景`、`校园`、`节日`、`纯色`、`高对比`、`复古`、`科技`

官方身份由 `source=official` 表示，不作为标签。

## 8. 错误码

Dart 和 Go 使用同一组错误码。界面上显示中文提示，详情里显示错误码和字段路径。

| 错误码 | 含义 | 中文提示 |
| --- | --- | --- |
| `theme_zip_invalid` | 不是 ZIP、ZIP 结构损坏，或条目 CRC32 不符 | 这不是有效的主题文件 |
| `theme_too_large` | 超过大小上限 | 主题文件过大 |
| `theme_manifest_invalid` | 缺少 manifest、JSON 不合法，或超过 64KB | 主题描述信息损坏 |
| `theme_field_invalid` | 字段缺失、类型错误、超出范围，或路径不合规 | 主题设置有误：{字段} |
| `theme_format_unsupported` | formatVersion 不受支持 | 这个主题需要更新版本的 App |
| `theme_app_too_old` | 当前 App 版本低于 minAppVersion | 请升级到 {版本} 后再使用 |
| `theme_asset_missing` | 引用的条目不存在 | 主题缺少图片：{路径} |
| `theme_image_invalid` | 图片无法解码，或尺寸、大小不合规 | 主题图片不符合要求：{路径} |
| `theme_contrast_low` | 对比度不达标（仅服务端报这个错误） | 文字与背景对比度不足：{前景} / {背景} |
| `theme_font_invalid` | 字体文件无法加载或解析 | 主题字体无法使用 |
| `theme_font_coverage_low` | 字体缺少常用汉字（仅服务端报这个错误） | 字体缺少常用汉字，覆盖率 {百分比} |

服务端在此基础上还有以下业务错误码：

| 错误码 | HTTP 状态 | 含义 |
| --- | --- | --- |
| `theme_not_found` | 404 | 主题不存在或不可访问 |
| `theme_quota` | 429 | 超出投稿配额 |
| `theme_conflict` | 409 | 状态冲突（例如审核一条已经处理过的记录） |
| `theme_forbidden` | 403 | 无权操作 |
| `theme_failed` | 500 | 其他服务端错误 |

## 9. 测试夹具

不提交二进制样例包。Dart 和 Go 各写一个测试辅助函数，在内存里生成主题包：输入一个 manifest map 和一个"路径 → 图片尺寸"的表，生成 1×1 放大到指定尺寸的纯色 PNG，然后打包成 ZIP。

两端各用一个表格驱动测试，覆盖第 8 节中的每个错误码，每个错误码至少一条反例，再加一条合法包。

`theme_zip_invalid` 必须包含这样一条用例：修改某个条目在本地文件头和中央目录中记录的 CRC32，让内容仍能正常解压，但 CRC 不符。这条用例用来证明 CRC 校验确实执行了。
