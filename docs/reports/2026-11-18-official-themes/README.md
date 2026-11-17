# P5 首批官方主题制作记录、许可台账与九页明暗归档

生成日期：2026-11-18
验证环境：隔离回环 Go 服务端 + Flutter 共享组件渲染舞台（390×844）

## 1. 已完成首批五套官方主题总览

五套官方主题共用现有单套 Flutter 组件体系，对比度检查全部为 0 告警，并已在隔离环境中通过维护者管理员账号（`source=official`）投稿、第二名管理员账号审核上架，`GET /api/themes?sort=official` 严格按下列顺序返回：

| 顺序 | 名称 | 目录 | 种子色 / 方案 | 圆角 | 页头模板与卡片样式 | 规范包大小 | 规范包 SHA-256 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | **沈理青** | `01-shenli-qing/` | `#147C72` / `tonalSpot` | `standard` | 全部默认 `standard`；默认卡片描边/阴影 | 12657 B | `88f4e6f0c7cb02a2e826d2aa995e17730a004651f4bc737b8f5fc70a8ec773e6` |
| 2 | **墨夜** | `02-mo-ye/` | `#5B7C8A` / `neutral` | `standard` | campus:`compact`、me:`compact`；描边 `1.0dp` / 阴影 `none` | 11906 B | `70763355e712ecde29dae05f8b3c587deab1c65446729932b28b1af74bdac67e` |
| 3 | **海盐蓝** | `03-haiyan-lan/` | `#2F7FD8` / `tonalSpot` | `standard` | home:`immersive`、me:`immersive`；描边 `1.0dp` / 阴影 `soft` | 23151 B | `62439e2ce427db1816ebaac9e47d72aff9d5833ca60d18827fcb00e9e9cc6fcf` |
| 4 | **樱粉** | `04-ying-fen/` | `#C9617E` / `tonalSpot` | `rounded` | campus:`compact`、me:`immersive`；描边 `0.5dp` / 阴影 `soft` | 20853 B | `a68ff2a01db4e41be48bed6b48e604629930001757dee10c462d994be4b84858` |
| 5 | **纸感** | `05-zhi-gan/` | `#3E6B4F` / `fidelity` | `compact` | home:`compact`、me:`compact`；描边 `1.0dp` / 阴影 `none` | 12164 B | `130ecf904f8921138ecbd04ef74ba2ff093c6c065deab2ab3e100e08021ed93e` |

## 2. 「沈理青」与内置默认外观的有意视觉差异单列验收

按制作细则第 9 节与契约第 3 节，「沈理青」不走种子色推导，直接以内置默认 `AppPalette.defaults` 为基础制作，保持全部默认标准布局。为满足商城上架的 WCAG 2.1 对比度门禁（正文与标签 ≥ 4.5:1），对内置默认值做了以下同色相最小色调步进修正：

- `light.tokens.textSecondary: #747B82 → #6E757C`（原值在白卡片上对比度 4.29，修正后为 4.67）
- `light.tokens.tagText: #147C72 → #107A70`（原值在 `tagBackground` `#EEF2F0` 上对比度 4.47，修正后 ≥ 4.5）

- 并排对比图：`01-shenli-qing/comparison-default-vs-shenli-qing-light.png`（左为内置默认亮色 `#747B82` = 4.29:1，右为官方主题「沈理青」亮色 `#6E757C` = 4.67:1）。

## 2.1 导出与复现命令

仓库只提交本索引文件（`docs/reports/2026-11-18-official-themes/README.md`）；`.sltheme` 二进制包与 91 张 PNG 截图不进入 git。在本机重新生成五套规范包与九页明暗截图的命令如下：

```powershell
cd client
flutter test --no-pub --concurrency 1 test/theme_pack/theme_store_test.dart --plain-name "P5 首批五套官方主题：工坊构建、对比度全绿、双管理员隔离上架与九页明暗截图归档"
```

执行后在 `artifacts/theme-p5/packages/` 生成 5 个服务端规范化 `.sltheme` 包，并在 `docs/reports/2026-11-18-official-themes/01-shenli-qing/` 至 `05-zhi-gan/` 生成全部九页明暗截图与默认对比图。

## 3. 素材来源与许可证台账

| 主题 | 主题包协议 | 包含资源文件 | 来源与版权说明 |
| --- | --- | --- | --- |
| 沈理青 | `CC-BY-4.0` | `preview/light.jpg`、`preview/dark.jpg` | 无外部图片/字体资源；使用内置思源黑体与 `ic_launcher_main` (`default`)。 |
| 墨夜 | `CC-BY-4.0` | `preview/light.jpg`、`preview/dark.jpg` | 无外部图片/字体；内置备选桌面图标 `night` 1024×1024 源图待维护者提供后补入安装包，当前按细则第 9 节省略 `launcherIcon`。 |
| 海盐蓝 | `CC-BY-4.0` | `preview/light.jpg`、`preview/dark.jpg`、`decorations/item_1.jpg`、`decorations/item_2.png`、`decorations/item_3.png`、`decorations/item_4.jpg` | 页头渐变背景与透明几何气泡贴纸由项目程序化原创生成（`CC0-1.0`）；备选图标 `sea` 源图待维护者提供。 |
| 樱粉 | `CC-BY-4.0` | `preview/light.jpg`、`preview/dark.jpg`、`decorations/item_1.jpg`、`decorations/item_2.png`、`decorations/item_3.jpg` | 页头渐变背景与透明几何花瓣贴纸由项目程序化原创生成（`CC0-1.0`）；备选图标 `sakura` 源图待维护者提供。 |
| 纸感 | `CC-BY-4.0` | `preview/light.jpg`、`preview/dark.jpg` | 霞鹜文楷（`LXGW WenKai`，`OFL-1.1`）GB2312+ASCII 双字重子集字体文件及 `paper` 图标源图未随离线仓库提供，当前不塞入伪造字体或占位图，沿用内置正文回退链。 |

## 4. 缺少的维护者素材与未记为完成项说明

以下项目因外部或维护者专属素材尚未提供，严格遵守“不拿重复占位图或未授权素材冒充完成”的规则单列说明：

1. **第六套官方主题「校园四季」（未制作、不计入已完成）**：需维护者提供 4 张拥有完整授权的沈阳理工大学校园实景照片（全局、首页、课表、我各一张）及全套 `template` 线性导航图标源图，待照片合入后再行制作。
2. **「纸感」外部霞鹜文楷字体文件（待补入新版本）**：离线工作区未附带 `LXGW WenKai`（`OFL-1.1`）TTF/OTF 源文件，当前 v1 包未嵌入伪造字体文件，正文回退使用内置 `NotoSansCJKsc`；待维护者提供子集化常规体与粗体文件后发布「纸感」v2。
3. **5 套非默认内置备选桌面图标源图（`night` / `sea` / `sakura` / `paper` / `campus`）**：需维护者提供 1024×1024 前景、背景色与中间 66% 单色透明剪影三件套源图随客户端发版打包；源图到位前仅「沈理青」声明 `launcherIcon.builtin = "default"`，其余 4 套按制作细则第 9 节省略 `launcherIcon`。
4. **生产环境上架**：本次仅在隔离回环服务端完成双管理员投稿与审核验证；正式生产环境投稿与审核须由维护者授权后使用真实管理员账号执行。

## 5. 九个首批页面明暗两套截图索引（共 90 张 + 1 张默认对比图）

### 沈理青（`01-shenli-qing`）
- 设计与参数摘要：基于内置默认值，保留全部标准页头布局与内置 `default` 桌面图标，修正浅色次要文字与对比度临界项。
- 亮色九页：`light-01-home.png`、`light-02-market.png`、`light-03-schedule.png`、`light-04-campus.png`、`light-05-me.png`、`light-06-user-home.png`、`light-07-settings.png`、`light-08-ai.png`、`light-09-toolbox.png`
- 暗色九页：`dark-01-home.png`、`dark-02-market.png`、`dark-03-schedule.png`、`dark-04-campus.png`、`dark-05-me.png`、`dark-06-user-home.png`、`dark-07-settings.png`、`dark-08-ai.png`、`dark-09-toolbox.png`

### 墨夜（`02-mo-ye`）
- 设计与参数摘要：种子 `#5B7C8A` (`neutral`)，暗色纯黑 `#000000` 底面与 `#0E1113` 卡片，`campus`/`me` 采用 `compact` 页头与 1dp 无阴影描边。
- 亮色九页：`light-01-home.png`、`light-02-market.png`、`light-03-schedule.png`、`light-04-campus.png`、`light-05-me.png`、`light-06-user-home.png`、`light-07-settings.png`、`light-08-ai.png`、`light-09-toolbox.png`
- 暗色九页：`dark-01-home.png`、`dark-02-market.png`、`dark-03-schedule.png`、`dark-04-campus.png`、`dark-05-me.png`、`dark-06-user-home.png`、`dark-07-settings.png`、`dark-08-ai.png`、`dark-09-toolbox.png`

### 海盐蓝（`03-haiyan-lan`）
- 设计与参数摘要：种子 `#2F7FD8` (`tonalSpot`)，亮色底 `#F5F9FF` 与 8 色蓝绿课表，`home`/`me` 采用 `immersive` 页头、矩阵调色与柔和卡片阴影。
- 亮色九页：`light-01-home.png`、`light-02-market.png`、`light-03-schedule.png`、`light-04-campus.png`、`light-05-me.png`、`light-06-user-home.png`、`light-07-settings.png`、`light-08-ai.png`、`light-09-toolbox.png`
- 暗色九页：`dark-01-home.png`、`dark-02-market.png`、`dark-03-schedule.png`、`dark-04-campus.png`、`dark-05-me.png`、`dark-06-user-home.png`、`dark-07-settings.png`、`dark-08-ai.png`、`dark-09-toolbox.png`

### 樱粉（`04-ying-fen`）
- 设计与参数摘要：种子 `#C9617E` (`tonalSpot`)，亮色底 `#FFF7F8`，`rounded` 圆角档位，`campus` 采用 `compact`、`me` 采用 `immersive` 页头与几何花瓣贴纸。
- 亮色九页：`light-01-home.png`、`light-02-market.png`、`light-03-schedule.png`、`light-04-campus.png`、`light-05-me.png`、`light-06-user-home.png`、`light-07-settings.png`、`light-08-ai.png`、`light-09-toolbox.png`
- 暗色九页：`dark-01-home.png`、`dark-02-market.png`、`dark-03-schedule.png`、`dark-04-campus.png`、`dark-05-me.png`、`dark-06-user-home.png`、`dark-07-settings.png`、`dark-08-ai.png`、`dark-09-toolbox.png`

### 纸感（`05-zhi-gan`）
- 设计与参数摘要：种子 `#3E6B4F` (`fidelity`)，亮色底 `#F6F0E2`、卡片 `#FBF7EE`，`compact` 圆角与 `home`/`me` 紧凑页头、1dp 纸感细边框无阴影。
- 亮色九页：`light-01-home.png`、`light-02-market.png`、`light-03-schedule.png`、`light-04-campus.png`、`light-05-me.png`、`light-06-user-home.png`、`light-07-settings.png`、`light-08-ai.png`、`light-09-toolbox.png`
- 暗色九页：`dark-01-home.png`、`dark-02-market.png`、`dark-03-schedule.png`、`dark-04-campus.png`、`dark-05-me.png`、`dark-06-user-home.png`、`dark-07-settings.png`、`dark-08-ai.png`、`dark-09-toolbox.png`

