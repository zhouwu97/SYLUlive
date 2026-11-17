# 本机主题包

入口：“我的 → 个性主题”或“界面设置 → 主题”。文件后缀为 `.sltheme`，ZIP 格式及基础字段遵循[格式契约](../../../../docs/design/theme-pack-contract.md)。支持选择文件或通过 Android/iOS 系统文件关联冷、热启动打开，完成校验、明暗预览、全局试用会话、按组应用、跨重启恢复、导出当前混搭外观、单份上一个外观、恢复手动外观，以及分享或保存已安装包。

应用分组开放全部十组：配色、圆角、壁纸、卡片材质（含 `cardStyle` 描边宽度与阴影）、导航栏、字体、桌面小部件、桌面图标（`launcherIcon` 默认不勾选）、页头布局（`home`、`campus`、`me` 的 `standard`/`compact`/`immersive` 模板、对齐与装饰区尺寸）、页头装饰（明暗独立的背景图、颜色矩阵调色及最多 5 张贴纸）。未勾选的组保留当前值；主题未包含的分组在导入页置灰。深浅配色跟随原有明暗设置，文字大小独立保存。全局试用会话通过顶部常驻横条跨页面生效，不写入任何偏好存储，进程退出后自然恢复原外观。外观设置页“布局与装饰”二级页支持直接修改卡片样式、三个页头模板与装饰并按槽位或分组重置；更换页头背景保留贴纸，手动调整卡片材质不清除 `cardStyle`。恢复上一个外观会交换两份完整快照；恢复手动外观使用现有手动偏好，且不改动已生效的桌面图标。

“导出当前外观”基于当前最终生效的混搭参数与引用资源重新打包，生成新的主题 ID 与 1080×2340 明暗预览图，支持系统分享和保存文件，导出产物可直接重新导入。系统文件关联在信任边界限制 48MB 体积并复制到受管临时目录 `incoming-theme/`，完成读取、取消或被新请求取代后自动清理，迟到的旧异步结果不会覆盖当前页面或应用旧主题。

ZIP／JSON 在工作 isolate 读取，实际解压输出上限 96MB，读取条目执行 ZIP 原生 CRC 校验，不另加资源哈希。图片先查尺寸再完整解码，只允许静态 PNG／JPEG／WebP。壁纸槽位切换使用 200ms 淡入淡出，开启减少动态效果时直接切换；壁纸与页头背景按显示物理宽度缩放解码，亮度／对比度／饱和度在渲染时使用 `ColorFilter.matrix`，遮罩使用当前 `background` Token 透明度合成；正式页头装饰区包裹 `IgnorePointer` 与 `ExcludeSemantics`，不遮挡资料或按钮交互。字体在校验边界检查必需 SFNT 表并用临时家族名试加载，应用与冷启动首帧通过 `FontLoader` 注册 `theme_font_<id>_<version>`，等宽字体保持不变；桌面小部件通过 `widget_app_palette_v1` 与 `coursePalette` 跟随 App 主题明暗配色；Android 桌面图标通过后台 `activity-alias` 与 `MY_PACKAGE_REPLACED` 安全切换，支持自定义主题快捷方式及 MIUI／HyperOS 权限引导（维护者备选图标源图合入前仅打包 `default`），iOS 接入 `setAlternateIconName`。

主题目录为应用 documents 下的 `themes/`。安装先写 `.staging/`，完成后 rename 到 `installed/<id>/<version>/`，索引只列每个 ID 的最新版本。所有写入复用 ThemeProvider 原有外观队列。当前外观、上一个外观、试用会话和手动壁纸偏好引用的文件均受保护；删除主题只移出列表，失去全部引用后清理旧版本。

验证入口：`flutter test test/theme_pack --concurrency 1`。已有表情包导入器复用同一条有输出上限的 ZIP 条目读取函数，修改时同时运行 `test/features/emoji/emoji_pack_importer_security_test.dart` 和 `emoji_pack_import_flow_test.dart`。真实渲染截图写入忽略提交的 `client/build/theme-p1-qa/`，不提交 Golden 或二进制夹具。
