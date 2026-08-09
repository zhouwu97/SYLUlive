# SYLUlive 动效契约（Motion System）

- 状态：**冻结 v1**（2026-08-09）
- 基线：`MCP` 分支当前工作树
- 重要：**AppMotion 已存在且在用（`client/lib/utils/app_motion.dart`），本协议以它为唯一权威实现，不创建第二套 AppMotion**。PR1 将把它 `git mv` 到 `client/lib/theme/app_motion.dart` 并审计数值。

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

## 3. Token（现有 AppMotion 权威清单）

```dart
// client/lib/utils/app_motion.dart（PR1 迁移至 theme/）
static const fast   = Duration(milliseconds: 160);
static const normal = Duration(milliseconds: 240);
static const nav    = Duration(milliseconds: 220);
static const reveal = Duration(milliseconds: 360);
static const page   = Duration(milliseconds: 320);
static const detail = Duration(milliseconds: 360);

static const standard = Curves.easeOutCubic;   // 进入/主要
static const incoming = Curves.easeOutCubic;   // 进入
static const outgoing = Curves.easeInCubic;    // 退出
```

- 数值通过真实设备 feel-check 调整，不复制 Web 的 cubic-bezier。
- 页面级 320/360ms 与 reveal 360ms 属于「大型过渡豁免」（规则 4）。

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

## 7. 当前已知动效现状（审计快照，2026-08-09）

| 位置 | 现状 | 判定 |
| --- | --- | --- |
| `home_screen.dart` | `_contentTabController` 建时 `AppMotion.nav`(220ms)，Tab 切换前 set 为 `380ms`；`HomeTabRevealItem` 用 `Interval(order*0.055, order*0.055+0.84)` | 见 §8 策略 B |
| `chat_detail_screen.dart` | 魔法值：`0 / 35 / 45 / 100 / 130 / 220ms` | PR3 迁移到 AppMotion |
| `shuitie_screen.dart` / `edu_grade_screen.dart` | `AppMotion.incoming / outgoing` | ✅ 已按 token |
| `AppMotion` 数值 | `reveal=360 / detail=360` | feel-check 后调整 |

## 8. HomeTabReveal 审计结论（冻结：策略 B）

- 实际时长修正：`Interval` 参数是归一化进度，非秒。controller 触发前被设为 380ms，最后一项 delay=7×0.055=0.385 → **约 146ms 开始，380ms 结束**（不是 1.2s）。
- 但当前行为是：**每次 Tab 切换都重放 stagger（位移 56px + 透明度 + scale 0.984）**。
- **冻结策略 B**：首次访问 Tab → 保留现有 reveal；重复切换（已访问过的 Tab）→ 不重放 stagger，最多 80–120ms opacity 过渡。
- 理由：频率优先（高频 Tab 不重播）而非时长。
- 执行：PR4 实现；实现时保留 token 值不变，只改触发条件。

## 9. Motion Audit 方法论（PR4 前执行）

扫描 `AnimatedContainer / AnimatedOpacity / AnimatedSwitcher / AnimationController / Tween / CurvedAnimation / SlideTransition / ScaleTransition / FadeTransition / Hero / Transform / showModalBottomSheet / PageRouteBuilder`，分类：`HIGH`（高频、有目的）/ `MEDIUM` / `LOW`（低频装饰）/ `MISSED OPPORTUNITY`（该有反馈但没有）。

## 10. 禁止事项

- 为几处 transition 引入大型动画依赖。
- 把 Web（CSS / Framer Motion / clip-path / hover）规则机械移植。
- 把每个可点击元素都 scale。
- 以「新页面更炫」为完成标准 —— 完成标准见 DESIGN_SYSTEM.md §12 与 PR checklist。