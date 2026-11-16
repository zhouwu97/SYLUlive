# 主题包格式契约（formatVersion 1）

本文是 `.sltheme` 主题包格式的唯一定义。

- 产品决策见 [ADR-005](adr/005-theme-package-and-store.md)；
- 实施步骤见 [实施计划](theme-store-plan.md)；
- 制作与审核要求见 [制作与审核细则](theme-creation-guide.md)；
- 实现时遵守 [AGENTS.md](../../AGENTS.md) 中「实现取舍：不过度防御」一节。

## 0. 设计要点

- **manifest 写完整的颜色值。** 主题工坊导出时，把明暗两套的全部 Token 都写进 manifest。这样服务端和 Web 端直接读取颜色值即可，不需要移植配色推导逻辑；推导只在 Dart 的工坊里做（见第 4 节）。
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
^(preview|wallpaper|icons)/[a-z0-9_-]{1,40}\.(webp|jpg|png)$
^fonts/[a-z0-9_-]{1,40}\.(ttf|otf)$
```

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

不认识的字段：客户端直接忽略；服务端在规范化时删除。

桌面小部件的配色不在 manifest 中单独声明，由明暗变体的 Token 映射得到，见 3.1 节。

### 2.2 明暗变体（`light`、`dark` 结构相同）

| 字段 | 类型 | 必填 | 约束 |
| --- | --- | --- | --- |
| `seedColor` | string | 是 | `#RRGGBB`。作为 Material 组件 `ColorScheme.fromSeed` 的输入 |
| `schemeVariant` | string | 否 | `tonalSpot`（默认）、`neutral`、`vibrant`、`expressive`、`fidelity`、`content` 之一 |
| `tokens` | object | 是 | 第 3 节的全部 Token 都要给出。值为 `#RRGGBB`；标注了"可透明"的 Token 也可以用 `#AARRGGBB` |
| `coursePalette` | string[] | 是 | 5–12 个 `#RRGGBB` |
| `wallpapers` | object | 否 | 键为 `global`、`home`、`schedule`、`me`，值为壁纸对象或 null |
| `componentOpacity` | number | 否 | 0.75–1.0，默认 1.0。明暗两套分别生效，系统切换明暗时随之切换 |
| `frostedGlass` | object | 否 | `{ "enabled": bool, "strength": 0–1 }` |

### 2.3 壁纸对象

| 字段 | 必填 | 约束 |
| --- | --- | --- |
| `portrait` | 是 | `wallpaper/` 下的路径 |
| `landscape` | 否 | `wallpaper/` 下的路径；缺省时横屏也用 `portrait` |
| `fit` | 否 | `cover`（默认）或 `contain` |
| `focalX`、`focalY` | 否 | 0–1，默认 0.5 |
| `blur` | 否 | 0–20，默认 0 |
| `scrim` | 否 | 0–0.6，默认 0。在壁纸上叠加一层 `background` 色，这是它的不透明度 |

页签与壁纸槽位的对应关系：

| 页签 | 使用的槽位 |
| --- | --- |
| 首页 | `home` |
| 课表 | `schedule` |
| 我 | `me` |
| 集市、校园 | `global` |

页面槽位为空时，回退到 `global`；`global` 也为空时，显示 `background` 纯色。

### 2.4 `bottomNav`

| 字段 | 约束 |
| --- | --- |
| `style` | `normal`、`floating`、`liquid_glass` 之一，与 `BottomNavStyle.storageValue` 一致 |
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
| `textDisabled` | 禁用文字 | P0 回填 | P0 回填 | |
| `divider` | 分割线 | `#E8EEE9` | `#252A2C` | ✓ |
| `outline` | 控件描边 | `#E2EFEA` | `#303638` | ✓ |
| `inputFill` | 输入框 | `#F2F3F1` | `#24282A` | |
| `inputFillFocused` | 输入框（聚焦） | `#EFF4F1` | `#2B3033` | |
| `searchFill` | 搜索框 | `#F1F2F0` | `#24282A` | |
| `tagBackground` | 标签底色 | `#EEF2F0` | `#282D30` | |
| `tagText` | 标签文字 | `#147C72` | `#90D5C7` | |
| `navBackground` | 底栏与侧栏 | P0 回填 | P0 回填 | ✓ |
| `navSelected` | 底栏选中项 | P0 回填 | P0 回填 | |
| `navUnselected` | 底栏未选中项 | P0 回填 | P0 回填 | |
| `appBarBackground` | 顶栏 | P0 回填 | P0 回填 | ✓ |
| `appBarForeground` | 顶栏内容 | P0 回填 | P0 回填 | |
| `bubbleIncoming` | 收到的消息气泡 | `#F0F1EF` | `#262A2C` | |
| `bubbleIncomingText` | 收到的消息文字 | `#1F2328` | `#F2F4F3` | |
| `bubbleOutgoing` | 发出的消息气泡 | `#76C4FF` | `#80C4FC` | |
| `bubbleOutgoingText` | 发出的消息文字 | `#1F2328` | `#111315` | |
| `feedSectionSurface` | 首页版块角标 | `#E8F5F1` | P0 回填 | |
| `feedFeaturedSurface` | 精华角标底色 | `#FFF3E0` | `#3A2A18` | |
| `feedFeaturedText` | 精华角标文字 | `#D97706` | `#F2B15A` | |
| `courseCardText` | 课表卡片文字 | `#1F2328` | `#FFFFFF` | |
| `timetableGrid` | 课表网格线 | P0 回填 | P0 回填 | ✓ |
| `timetableToday` | 课表"今天"列 | P0 回填 | P0 回填 | ✓ |

**默认值与对比度规则的关系**：默认的 `textSecondary` 亮色值 `#747B82`，在 `card`（`#FFFFFF`）上的对比度为 4.29，在 `background`（`#FFFAF4`）上为 4.13，达不到第 5 节要求的 4.5。

- 内置默认外观保持这个现值，P0 要求像素不变，并且内置默认外观不经过商城的对比度检查。
- 官方主题"沈理青"把亮色 `textSecondary` 改为 `#6E757C`（在 `card` 上为 4.67，在 `background` 上为 4.5），其余颜色沿用默认值。

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
| `textPrimary`、`bubbleIncomingText`、`appBarForeground`、`courseCardText` | `onSurface` |
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

**课程色板生成**：

1. 用 `Hct` 读取种子色的色相 H。`material_color_utilities` 已经由 Flutter SDK 引入，在 `pubspec.yaml` 中声明为直接依赖，版本写 `any`。
2. 生成 8 个颜色，第 i 个的色相为 `H + i × 45`。色度：亮色 48，暗色 40。色调：亮色 60，暗色 70。
3. 每个颜色和课程文字的对比度达不到 4.5 时，用下面的"自动修正"调整。

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
| `courseCardText` | 色板中每个颜色以 0.45 不透明度合成到 `background` 后的颜色 | 4.5 |
| `navSelected`、`navUnselected` | `navBackground` | 3.0 |

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

**字体文件**：

- 客户端：用 `FontLoader` 加载，加载失败时报 `theme_font_invalid`。
- 服务端：
  - 用 `golang.org/x/image/font/sfnt`（`x/image` 已经是现有依赖）解析，解析失败时报 `theme_font_invalid`；
  - 检查字形覆盖：可打印 ASCII 全部覆盖，GB2312 一级汉字（3755 个）至少覆盖 99%，否则报 `theme_font_coverage_low`。一级汉字列表用 `golang.org/x/text/encoding/simplifiedchinese` 解码 GB2312 的 0xB0A1–0xD7F9 区间得到，`x/text` 已经是现有的间接依赖，改为直接依赖；
  - 字体文件不重新编码，原样放进规范包。

**尺寸检查**：先只读取图片头部拿到尺寸，超出限制就直接拒绝，不做完整解码。Dart 端用 `ui.ImageDescriptor`，Go 端用 `image.DecodeConfig`。

**服务端规范化**：

- 重新编码全部图片，同时去掉元数据：壁纸和预览图编码为 JPEG（质量 88），图标编码为 PNG；
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
