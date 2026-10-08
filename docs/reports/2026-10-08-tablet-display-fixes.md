# Pad 显示适配修复记录

- 日期：2026-10-08（Asia/Shanghai）
- 范围：用户要求修复[审核报告](2026-10-08-tablet-display-audit.md)中除 F1 外的问题。
- 基准：分支 `zhou`，提交 `6e8062e8d3a9ed2682496149d6e572d57a16b861`；本记录对应以该提交为基准的本次 Pad 适配变更。
- 风险：R1，布局、导航状态保留和本地验证；未改变认证、上传、接口、数据存储或发布契约。
- 环境：Windows，Flutter 3.41.8 stable / Dart 3.11.5；隔离测试数据与本机离屏渲染。

## Changed

| 审核项 | 修复结果 | 主要入口 |
| --- | --- | --- |
| F1 课表 840px 挤压 | 按用户要求保留；课表源码和全局 600 / 840 断点未改变 | `course_schedule_screen.dart` |
| F2 地图退出后锁竖屏 | 关闭横屏约束或退出页面时恢复系统方向策略 `[]`；处理中禁止重复操作；请求未完成时离开也恢复 | `campus_map_tab_page.dart` |
| F3 商品详情固化打开时布局 | 按当前内容宽度重新选择单栏／双栏；有图且宽度至少 840px 才分栏；无图正文限宽 840px；回复组件和滚动控制器保留 | `post_detail_screen.dart`、`market_screen.dart` |
| F4 两列卡片过大 | 食堂菜品、热门菜品、集市瀑布流按局部宽度增列；1280px 下为四列；发布图片按 180px 目标增列，保留添加、预览、删除、拖拽和失败状态 | `responsive_util.dart`、三个列表页、`publish_image_grid.dart` |
| F5 AI 文本与输入横向铺满 | 对话与输入统一居中，最大 840px；宽内容区四项能力同排，大字号回到两列；卡片高度随内容增长 | `ai_assistant_screen.dart`、`ai_action_grid.dart`、两种空态 |
| F6 阅读／表单缺少限宽 | 复用 `ResponsiveContent`：登录、试卷投稿／编辑 680px；文章、成绩、个人页 840px；校园、竞赛、试卷聚合列表 1000px | 对应页面、`responsive_content.dart` |
| F7 外壳与分栏宽度预算 | 水贴按扣除 rail 后的实际宽度判断 380 + 460px 分栏；收窄保留已打开详情、焦点和草稿；嵌入用户主页加载／失败时也能返回；首页两种外壳共用相同 Tab Element 路径；悬浮 Dock 最大 640px 且居中 | `home_screen.dart`、`shuitie_screen.dart`、`user_home_screen.dart`、`bottom_nav.dart` |
| F8 缺少 Pad 回归矩阵 | 新增统一视口常量、连续 resize 用例和设计 QA 补充矩阵；保留手机 canonical 基线及 Linux 更新规则 | `golden_viewport.dart`、新增专项测试、`DESIGN_QA.md` |

内容宽度规则已写入[设计系统](../design/DESIGN_SYSTEM.md)，Pad 验收入口写入[设计 QA](../design/DESIGN_QA.md)。图库使用大屏空间，阅读和表单按各自用途限宽。

## Preserved

- 第一项课表问题保留，课表源码无差异；既有课表切周和大字号回归通过。
- 品牌、主题、圆角、动效、导航风格偏好和功能开关保留；私聊仍关闭。
- 请求、缓存、账号隔离、上传权限和发布业务逻辑保留；本轮只改变相应界面布局。
- 登录全页点击收起键盘保留，包括表单外侧的新增留白区域。
- 工作区其他任务的变更未由本任务编辑；未部署或生成正式安装包。用户后续明确授权提交并推送本次 Pad 适配，提交文案使用中文。

## Tests

### 最终定向回归

在 `client/` 执行以下命令；完整测试文件列表见 [fix-test-files.txt](assets/2026-10-08-tablet-display-fixes/fix-test-files.txt)：

```powershell
$padTests = Get-Content ../docs/reports/assets/2026-10-08-tablet-display-fixes/fix-test-files.txt
flutter test --no-pub --dart-define=TABLET_CAPTURE=true @padTests --reporter expanded
```

结果：**31 个测试文件、276 个用例全部通过**。[最终验证记录](assets/2026-10-08-tablet-display-fixes/verification.md#fix-all-verified)

专项尺寸：600×800 dark 1.3×、768×1024、834×1194、839 / 840×1024、1024×768 dark 1.5×、1280×800。另保留既有手机、320px、dark、评论输入和账号竞态回归。

| 前置条件 → 操作 | 预期与实际结果 |
| --- | --- |
| 地图 → 请求横屏 → 恢复或离开；另在未完成请求时离开 | 最后一个方向调用为 `[]`，没有强制 portraitUp，也没有销毁后更新 State |
| 有图商品 → 输入草稿 → 反复 600 ↔ 1280 resize，模拟 240px 键盘 | 单／双栏即时切换；详情 State、文字和焦点保留；输入位于键盘上方 |
| 无图商品 → 1280px | 单栏正文；不再留约 44% 的“没有图片展示”区域 |
| 水贴 840px → 分别启用悬浮导航与 104px rail 占宽 | 悬浮模式可分栏；rail 后内容不足时打开正常单栏详情，输入宽度超过 300px |
| 水贴宽屏详情 → 草稿 → 600 / 1280 / 834 resize → 返回 | 详情 State、草稿、焦点保留；输入在模拟键盘上方；返回恢复原列表和筛选 |
| 嵌入用户主页请求失败 → 收窄 → 返回 | 有返回入口并恢复水贴列表，不误退出首页 |
| 首页集市 → 搜索草稿 → normal 导航 → 834 / 1280 / 600 | 页面 State 和搜索草稿保留；rail 按宽度出现／消失 |
| 悬浮 Dock → 1280 / 600 resize → 点击首尾 Tab | 宽度分别为 640 / 576px，居中；点击坐标与选中状态一致 |
| 菜品／集市 → 七档尺寸 | 横屏增列，卡片宽度不超过 320px；无布局异常 |
| AI → 七档尺寸 → 点击能力 → 切个人助手 | 输入内容填入；两种空态可渲染；1.3 / 1.5× 无 overflow |
| 登录 → 大屏输入 → 点击表单外留白 | 内容限宽且居中，输入可用；焦点正确退出 |
| 校园文章 → 请求失败 → 点击重试 → 横竖屏切换 | 重试成功显示正文，阅读区域最大 840px |
| 成绩、个人页、竞赛、试卷 → resize / 页内切换 | 内容限宽，数据、选择和原有权限／失败／恢复用例通过 |

### Golden 与静态分析

- `flutter test --no-pub test/goldens --reporter expanded`：**11 个基础设施用例通过、1 个私聊 Golden 按既有功能开关跳过**。本次没有执行产品像素比较，也没有更新 canonical PNG。[验证记录](assets/2026-10-08-tablet-display-fixes/verification.md#fix-golden-check)
- 对所有受影响 Dart 文件及新增文件执行定向分析：**0 error、13 warning、25 info**；告警来自既存未使用成员、空断言、弃用 API 和 async context，未作为本轮适配修复扩大处理。静态分析不标记为完全通过。[验证记录](assets/2026-10-08-tablet-display-fixes/verification.md#fix-analyze-verified)、[文件列表](assets/2026-10-08-tablet-display-fixes/fix-analyzed-files.txt)
- `git diff --check`：受影响源码与设计文档通过。确认课表源码无 diff。

### 首次失败与修正

保留首次失败，不以重复执行抹掉记录：

- 初次批量插入宽度约束误匹配了 AI 的通知 `body` 字段，格式／编译检查发现后修正；另一次命令使用了错误相对工作目录。最终源码编译和全部受影响回归通过。
- [初次 Pad 日志](assets/2026-10-08-tablet-display-fixes/verification.md#fix-pad-first)：图片夹具应使用 PostImage 对象、导航 helper 覆盖了视口、宽度断言读到了外层 Align；纠正夹具、统一视口和测量对象，保留原来的宽度／焦点要求。
- [初次模块日志](assets/2026-10-08-tablet-display-fixes/verification.md#fix-module-regression)：热门菜品夹具没有图片，试卷夹具缺学生认证，校园请求受到共享拦截器时序影响；补齐真实状态前置条件并隔离响应。
- [校园重试过程](assets/2026-10-08-tablet-display-fixes/verification.md#fix-pad-final)：将失败夹具前置到拦截器链并使用确定性的失败响应，验证点击重试后正文确实出现。
- [最终集合首跑](assets/2026-10-08-tablet-display-fixes/verification.md#fix-all-final)：新登录焦点断言读了允许为空的 TextField.focusNode；改为验证实际 EditableText 的有效焦点，要求仍为“点击前有焦点，点击留白后无焦点”。最终 276 项全部通过。

## 真实渲染证据

以下图片使用生产 Theme 和项目 CJK 字体，从实际 Flutter 页面离屏渲染生成；网络图片为隔离失败占位。已检查大屏信息密度、居中、文字换行和深色大字号。它们不能替代 Pad 生产包截图；部分 Material Icons、AppBar／按钮字形仍受 headless 字体环境限制，不能按空 glyph 判为生产显示缺陷。

| 页面 | 修改前 | 修改后 |
| --- | --- | --- |
| AI 1280×800 | [原图](assets/2026-10-08-tablet-display-audit/ai-landscape.png) | [限宽与四项同排](assets/2026-10-08-tablet-display-fixes/ai-1280.png) |
| 菜品 1280×800 | [原图](assets/2026-10-08-tablet-display-audit/dishes-landscape.png) | [四列网格](assets/2026-10-08-tablet-display-fixes/dishes-1280.png) |
| 集市 1280×800 | [原图](assets/2026-10-08-tablet-display-audit/market-landscape.png) | [四列瀑布流](assets/2026-10-08-tablet-display-fixes/market-1280.png) |

补充：[AI 600px dark 1.3×](assets/2026-10-08-tablet-display-fixes/ai-600.png)、[个人助手 1024px dark 1.5×](assets/2026-10-08-tablet-display-fixes/ai-personal-1024.png)、[登录 1024px dark 1.5×](assets/2026-10-08-tablet-display-fixes/login-1024.png)。

## Design QA

- **P0**：本轮测试及渲染范围未发现核心操作遮挡、输入不可用或导航失效。
- **P1**：F2 方向恢复已修复并验证平台通道调用与离开竞态；F1 课表问题按用户要求保留，仍为已知 P1。
- **P2**：F3–F7 的代码适配修复及定向验收通过；F8 的 Pad 回归矩阵与门禁入口已补，Linux Pad 像素基线尚未生成。
- **P3**：未扩大到字体、图标、品牌或装饰性整理。

## Deferred

- Android 平板／iPad 真机的方向 API 响应、系统方向锁、真实软键盘／分屏和生产包操作验收。
- Linux 上的 Pad 产品 Golden 像素基线及审阅；Windows 本机禁止更新 canonical 基线。
- 原生 HarmonyOS NEXT Pad 的设备声明、HAP 分发和真机支持属于原审核的条件性平台缺口，本轮没有扩展原生平台支持范围。
- 折叠屏 display features、极端大字体、GPU／blur 性能与长时间使用验收。

交付状态：**代码已实现，列出的本机验证已执行；未形成正式发布或部署结论。** 回退入口为本任务的 client 布局与测试差异，不涉及数据回滚。
