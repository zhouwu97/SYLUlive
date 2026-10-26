# 桌面小组件背景与文字主题不同步复验

- 日期：2026-10-26；基准：`ce8dfec40bcce0481e6c016efd82840f496f471f` 加现有未提交修改。
- 用户现象：课表小组件改为深色后，课程文字变浅，整页仍是白色背景；标题也保留旧主题。模拟器偏好确认为深色、超大字号、材质关闭。
- 风险：R2（异步竞态与旧系统兼容），仅涉及 Android 小组件更新和验证，不更改教务数据或权限。

## Changed

- 新版 Android 的旧式服务列表存在两条异步更新链路：`updateAppWidget` 转换服务条目；`notifyAppWidgetViewDataChanged` 取缓存的整页 RemoteViews、替换条目后再次提交。旧整页背景可能晚于新主题到达，而服务条目读取的是最新主题，形成白底浅字。
- 本机 SDK 37 `AppWidgetManager.java` 的 `tryAdapterConversion`、`notifyCollectionWidgetChange` 验证了这一机制。迁移方式遵循 [Android 官方集合小组件指南](https://developer.android.com/develop/ui/views/appwidgets/collections#use-remote-collections)。
- Android 12/API 31 及以上使用 `RemoteCollectionItems`，将背景、标题、字号及列表条目作为同一份外观快照一次提交；条目构建只加载内容，不再次读取全局外观。
- 这一路径停止发送旧式数据变更通知，避免平台异步重发旧背景。手动刷新、首次添加及后台刷新均使用相同路径；全量刷新串行执行。
- Android 11 及以下保留服务列表与数据变更通知。原先的工厂复用、并发保护和缓存隔离继续保留。

## Preserved

- 保留用户现有桌面小组件，不删除或重新添加；保留课表和考试数据、字号、标题、独立材质开关、空状态、点击入口及条目数量。
- 恢复验证前的课表深色／超大字号／材质关闭设置，考试设置不变。
- 保留工作区既有 UI、通知、Web 和官网修改；本次未提交、推送或部署。

## Tests

- 原生定向测试 **10 passed**，覆盖 API 28、31、34：
  - 现有工厂复用、并发刷新、字号和日夜切换。
  - 四种课表／考试尺寸，在同一桌面宿主上反复 `apply/reapply` 浅色、深色、校园蓝及两种材质。
  - 构建后更改全局主题，再延迟应用；背景 RGB、标题、条目颜色和字号仍保持同一个捕获值。
  - API 31 无效缓存降级空状态及有效内容恢复，API 28 兼容路径。
- 测试首次以普通 FrameLayout 挂接列表失败；改为真正的 `AppWidgetHostView` 后验证实际集合适配器，保留原始失败证据，不将测试宿主问题当成产品修复证据。
- Flutter 小组件契约、配置和设置界面定向测试 **35 passed**；相关静态分析 **No issues found**。
- Debug APK 构建成功，`adb install -r` 保留数据安装；`git diff --check` 通过。
- 证据：`.evidence/widget-theme-sync/native-final.txt`、`flutter-tests.txt`、`flutter-analyze.txt`、`build-final.txt`。截图与原始设备数据不提交。

### 真实设备链路

- 环境：现有 Pixel 8 API 37.1 模拟器、已有 2×2 课表小组件。
- 安装前：偏好是深色，但背景白色、标题黑色，课程文字浅色（用户图片及 `before.png`）。
- 安装后：沿用原实例连续切换浅色 → 深色 → 校园蓝；每种背景、标题和课程文字同步变化。独立材质打开后再切深色，整面半透明背景和文字同步变化。
- 补充连续来回切换并恢复原设置；不通过删除重建小组件或清空缓存规避问题。
- 点击原实例的课程条目，正常打开 App 课表；结束时回到系统桌面展示修复后的深色小组件。
- 截图：`desktop-light.png`、`desktop-dark.png`、`desktop-blue.png`、`desktop-dark-glass.png`、`final-dark.png`。

## Design QA

- P0：无操作阻断、数据清除或权限变化。
- P1：修复异步旧背景覆盖新文字的错配；延迟应用和同实例连续切换通过。
- P2：背景、标题、条目语义颜色及透明度一致；沿用原有尺寸、边框和材质设计。
- P3：无新增问题。

## Deferred

- 实体厂商启动器未逐台测试；API 28/31/34 使用原生测试，API 37.1 使用实际桌面验证。
- 未执行无关模块全量测试或 canonical Golden 更新；未发布或部署。
- 回退可恢复原服务列表路径；不需要迁移或删除用户偏好与数据。该回退会重新带回新版系统异步覆盖的风险。
