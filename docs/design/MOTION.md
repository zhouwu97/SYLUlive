# SYLUlive 动效契约（Motion System）

- 状态：**冻结 v1（合同修订；movement 曲线待真机 A/B）**（2026-08-09）
- 基线：`MCP` 分支当前工作树
- 重要：**AppMotion 已存在且在用（`client/lib/theme/app_motion.dart`），本协议以它为唯一权威实现，不创建第二套 AppMotion**。`client/lib/utils/app_motion.dart` 仅作为临时 deprecated export shim。

## 1. 第一原则：频率优先

问题不是「哪里可以加动画」，而是「这里到底**需不需要**动画」。

用户按下后是不是立刻知道发生了什么？——这是唯一判断标准。动画必须服务于理解与反馈，不是装饰。

## 2. 频率分级

| 频率 | 例子 | 处理 |
| --- | --- | --- |
| 高频（每秒数次 ~ 每操作） | 输入文字、切聊天、滚动、高频 Tab、发送消息、返回 | **无动画或极短反馈（≤120ms）** |
| 中高频（每分钟数次） | 点赞、收藏、展开工具栏、切换筛选 | 120–180ms |
| 偶发 | BottomSheet、Dialog、图片选择、操作菜单 | 200–300ms |
| 稀有 | 首次引导、重大完成状态 | 允许较明显 delight |

## 3. Token（AppMotion 权威清单）

```dart
// client/lib/theme/app_motion.dart
static const micro   = Duration(milliseconds: 100); // 高频反馈
static const tab     = Duration(milliseconds: 120); // indicator / 轻反馈
static const fast    = Duration(milliseconds: 160);
static const normal  = Duration(milliseconds: 220);
static const overlay = Duration(milliseconds: 240);
static const page    = Duration(milliseconds: 280);
static const reveal  = Duration(milliseconds: 320); // 仅首次内容建立

static const standard = Curves.easeOutCubic;   // 进入/主要
static const incoming = Curves.easeOutCubic;   // 进入
static const outgoing = Curves.easeOutCubic;   // 退出
static const movement = Curves.easeInOutCubic; // 当前候选：已存在对象的 A → B
```

- `movement` 当前只作为候选实现；必须与 `Curves.easeOutCubic` 做 60Hz 真机 A/B，再冻结最终曲线。Widget/Golden 只能验证状态与布局，不能代替 feel-check。
- 数值通过真实设备 feel-check 调整，不复制 Web 的 cubic-bezier。
- `utils/app_motion.dart` 中的 `nav`（旧 220ms）与 `detail`（旧 360ms）是临时兼容别名；新代码不得继续使用。

### 3.1 旧 → 新迁移表

| 旧 token | 新 token | 迁移说明 |
| --- | --- | --- |
| `nav`（220ms） | `tab`（120ms） | 高频 Tab / indicator 使用；运行时行为变化，必须单独验证快速 retarget |
| `normal`（240ms） | `normal`（220ms） | 普通组件变化统一收敛，调用点需按状态矩阵复核 |
| `detail`（360ms） | `page`（280ms） | 页面空间关系逐步收窄；旧值仅保留兼容，不得新增引用 |
| `reveal`（360ms） | `reveal`（320ms） | 首次内容建立；幅度同时收敛到 10–12px |
| `outgoing: easeInCubic` | `outgoing: easeOutCubic` | 运行时行为变化，不能作为纯文件迁移隐藏 |

`AppMotion` 的旧别名将在全部生产调用点迁移并完成回滚窗口后删除。

## 4. 硬规则

### R1 进入/退出 UI：进入优先 ease-out
避免 ease-in 造成初始反馈迟钝。

### R2 高频操作：宁可删动画
输入、发送、Tab、返回、滚动绝对不能被动画拖慢。

### R3 动画不阻塞输入
聊天输入、发送、Tab、返回、滚动期间动画不得阻塞或抢占输入事件。

### R4 上限
UI 动画通常 ≤ 300ms；BottomSheet / 大型 Modal / 页面转场可按系统动画例外。

### R5 中断
手势动画必须可中断。滑动/拖拽/消失使用 AnimationController + spring simulation + gesture velocity，**禁止**「到达固定距离 → 播一段不可中断 tween」。

### R6 性能
- 优先 `Transform` / `Opacity`（不触发重排）
- 谨慎直接动画 `height / width / padding / margin`（尤其大列表）
- 大列表 rebuild 时避免整表重建；Blur / BackdropFilter 高成本，不作默认转场手段（不机械照搬 Web 的 blur-crossfade）。

## 5. 触控反馈（Press 分层）

| 元素 | 反馈 |
| --- | --- |
| 小型 icon action（返回/更多/附件/点赞/收藏） | Material state layer（InkResponse / InkWell），hit target ≥44 |
| 主按钮（发布/保存/确认/加入） | 轻量 opacity/scale，100–140ms |
| 可点击 Card | 仅可点 Card 有 pressed surface；**不可点 Card 不得看起来可按**（不得为展示卡加 scale） |

### Haptics
- 仅：重要 toggle、长按成功触发、拖拽到 snap 点、破坏性确认、特殊完成状态。
- **禁止**：每次按钮点击 / 每次 Tab / 每次列表选中 / 每条消息发送。

## 6. Reduced Motion

- 读取 `MediaQuery.disableAnimationsOf(context)`。
- 降低后：保留 opacity / color 反馈；移除大距离位移动画 / scale / decorative stagger；**不简单粗暴全部置 0**。

## 7. 修复前动效审计快照（2026-08-09）

| 位置 | 现状 | 判定 |
| --- | --- | --- |
| `home_screen.dart` | `_contentTabController` 建时 `AppMotion.nav`(220ms)，Tab 切换前 set 为 `380ms`；`HomeTabRevealItem` 用 `Interval(order*0.055, order*0.055+0.84)` | 见 §8 策略 B |
| `chat_detail_screen.dart` | 魔法值：`0 / 35 / 45 / 100 / 130 / 220ms` | PR3 迁移到 AppMotion |
| `shuitie_screen.dart` / `edu_grade_screen.dart` | `AppMotion.incoming / outgoing` | ✅ 已按 token |
| `AppMotion` 数值 | `reveal=360 / detail=360` | feel-check 后调整 |

本分支的实现状态：Root Tab / Feed indicator 已迁移到局部 `ValueNotifier`，Feed 内容不再套用逐条 reveal；上述表格保留为迁移前证据，避免把历史行为误读为当前合同。

## 8. HomeTabReveal 审计结论（冻结：策略 B，合同修订）

- 实际时长修正：`Interval` 参数是归一化进度，非秒。controller 触发前被设为 380ms，最后一项 delay=7×0.055=0.385 → **约 146ms 开始，380ms 结束**（不是 1.2s）。
- 合同修订为：首次访问 Tab → 仅首屏 3–4 个高价值元素做 `translateY: 10–12px → 0`、`opacity: 0.92–0.96 → 1`、`scale: 0.995 → 1`，`AppMotion.reveal` 约 320ms，stagger 间隔 20–35ms。
- 重复切换（已访问过的 Tab）→ 不重放位移、scale 或 stagger；只有出现明显闪变时，最多保留 80–100ms opacity bridge。
- 高频 Feed 内容不进入 HomeTabReveal；Feed 切换只改变内容与 indicator，不对帖子逐条 stagger。
- 理由：频率优先（高频 Tab 不重播）而非时长。
- 执行：PR4A-2 已在本分支实现；本节合同变更记录必须保留，不得静默覆盖冻结条款。

### 8.1 Feel-check 证据门槛

以下证据是合同验收的一部分，Widget/Golden 不能替代：

| 环境 | 状态 | 记录要求 |
| --- | --- | --- |
| 60Hz 真机 | 必测 | 连续切 Tab、A→B→C retarget、取消、反向操作 |
| 90Hz 真机 | 有硬件则测 | 记录设备与缺项，不因无设备阻塞静态实现 |
| 120Hz 真机 | 有硬件则测 | 记录设备与缺项，不因无设备阻塞静态实现 |
| Windows/Chrome | 仅回归辅助 | 可验证状态与布局，不能声称完成真机 feel-check |

当前仓库环境未连接 Android 真机；本分支只记录静态/Widget 验证结果，真机体验需在设备可用后补录。
证据登记见 [`FEEL_CHECK.md`](./FEEL_CHECK.md)。

## 9. Motion Audit 方法论（PR4 前执行）

扫描 `AnimatedContainer / AnimatedOpacity / AnimatedSwitcher / AnimationController / Tween / CurvedAnimation / SlideTransition / ScaleTransition / FadeTransition / Hero / Transform / showModalBottomSheet / PageRouteBuilder`，分类：`HIGH`（高频、有目的）/ `MEDIUM` / `LOW`（低频装饰）/ `MISSED OPPORTUNITY`（该有反馈但没有）。

## 10. 禁止事项

- 为几处 transition 引入大型动画依赖。
- 把 Web（CSS / Framer Motion / clip-path / hover）规则机械移植。
- 把每个可点击元素都 scale。
- 以「新页面更炫」为完成标准 —— 完成标准见 DESIGN_SYSTEM.md §12 与 PR checklist。
