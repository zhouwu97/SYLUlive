# SYLUlive 使用体验优化执行计划 v3

**仓库：** `zhouwu97/SYLUlive`
**正式执行基线：** `MCP`
**基线提交：** `7bdf3a3ac29c1592edf567ce5efd503d31def76e`
**计划类型：** UX / Interaction / State Feedback / Information Architecture
**禁止将本计划理解为全项目 UI 重做。**

---

## 0.1 三轨结构（2026-08-10 修订）

本计划（轨道 U）只包含 UX-0 ~ UX-7。推荐系统与发帖体验改造已彻底拆出，
不得再并入本计划的任何 UX PR。

```text
轨道 U：本计划 UX-0 ~ UX-7（当前主轨）
轨道 R：帖子分发 / 个性化推荐 → docs/plans/feed-recommendation-plan.md（FEED-0 ~ FEED-7）
轨道 C：发帖创作体验           → docs/plans/composer-experience-plan.md（C-1 ~ C-3）
```

R / C 必须遵守本计划的文件占用与合并顺序，硬规则见文末
「# 21. Parallel Track Conflict Rule」。

---

# 0. 总目标

本轮不追求继续“换皮”“增加动画”“做更多卡片”。

核心目标只有一句：

> **减少用户猜测、误触、等待和页面跳动，让高频操作的结果立即、稳定、可预期。**

重点处理：

1. 根导航横滑与页面局部横滑冲突；
2. Feed 浏览过程中后台刷新破坏阅读位置；
3. Feed 点赞/评论必须进入详情才能操作；
4. 私信已经有 SSE，但页面仍固定 polling；
5. 公告优先级语义尚未完全收敛；
6. Campus 缺少真正面向“今天”的高频信息入口；
7. 课表缺少数据新鲜度和“回到本周”；
8. Feed 卡片信息层级仍偏重。

---

# 1. 当前代码事实冻结

开始开发前，AI 必须接受以下事实，不允许重新实现已经存在的能力。

## 1.1 已完成，不得重复

### Design System / Motion

PR #65 已经将 `codex/ui-motion-consistency` 合入 `MCP`。

已有：

* `AppColors`
* `AppSpacing`
* `AppRadius`
* `AppTextStyles`
* `AppMotion`
* 页面 motion consistency
* reduced-motion 基础
* Chat 部分交互/滚动动效改进
* Campus surface / motion 改进
* Admin 页面 token 迁移
* 候选人分页

本计划中新 UI 必须复用这些能力。

**禁止创建：**

```text
AppUxColors
NewMotion
UxSpacing
UxTheme
FeedThemeV2
ChatThemeV2
```

等第二套体系。

---

## 1.2 根导航

一级页面固定为：

```text
0 首页   → ShuitieScreen
1 集市   → MarketScreen
2 课表   → CourseScheduleScreen
3 校园   → CampusScreen
4 我     → ProfileScreen
```

当前 `HomeScreen` 外层仍有整页 Pointer Listener 和 root swipe 状态机。

并存在：

```text
mainNavigationGestureZoneHeight = 120
mainNavigationRequiresBottomZone()
isMainNavigationGestureZone()
```

目前：

* 首页 / 集市 / 课表的 root swipe 主要受底部 120 px 限制；
* 校园 / 我的 root swipe 可全屏触发；
* Feed、课表为了避让 root swipe，又不能在底部 120 px 使用自己的局部横滑。

这就是本轮 P0 首要处理对象。

---

## 1.3 Feed

当前有：

```text
综合 all
最新 time
精华 featured
关注 following
```

并保留每个 mode 独立 ScrollController / Provider state。

当前约每 60 秒自动 refresh。

问题不是“不会刷新”，而是：

> **后台刷新直接更新当前可见列表。**

用户正在看第 10、20、30 条帖子时，不应该突然被新列表改变阅读上下文。

---

## 1.4 点赞

现有服务端接口：

```http
POST   /posts/:id/like
DELETE /posts/:id/like
```

不是 toggle API。

`PostDetailScreen` 已经存在一套本地 optimistic like。

`PostProvider` 已经存在：

```text
likePost()
unlikePost()
updatePostInCache()
applyExternalPostUpdate()
```

本轮禁止在 PostCard 新写第二套点赞状态机。

---

## 1.5 私信

已经存在 SSE：

```http
GET /messages/events
Accept: text/event-stream
```

客户端 `MessageProvider` 已经支持：

* SSE stream；
* 1 → 2 → 4 → ... → 15 秒退避；
* `message.created`；
* `message.read`；
* `message.id` 去重；
* `client_message_id` pending reconciliation；
* logout / account switch 停止 realtime。

所以：

> **禁止重新实现 WebSocket。**

当前真实问题：

```text
SSE
+
ChatList 30 秒 polling
+
ChatDetail 25/45 秒 polling
```

同时工作。

---

## 1.6 公告

已经存在：

* normal 不强弹；
* urgent / important candidate 筛选；
* unread badge；
* session seen；
* dismissed；
* snooze；
* read API；
* `/notices` 和 `/announcements` alias。

所以公告不是大重构项目。

需要处理的是**优先级语义**。

---

## 1.7 Campus

一级 Campus 根页面就是：

```text
CampusScreen
```

当前结构已经是：

```text
学期 Header
最新校园资讯
AI
校园服务
校园资讯列表
```

`EduScreen` 是 Campus 内的二级教务入口，不是 Campus 根页面。

Today 必须加在 `CampusScreen`。

---

## 1.8 课表

已有：

* cache first；
* fetch pending 防重复；
* 导入失败不清空当前课表；
* 多学期；
* 拉取其他学期后自动切换；
* `ScheduleVaultSnapshot.fetchedAt`；
* 周切换；
* 学期切换。

本轮不要重新设计课表数据层。

---

# 2. 全局 UX 合同

所有 PR 都必须遵守下面规则。

## 2.1 根导航

一级页面：

```text
首页 / 集市 / 课表 / 校园 / 我
```

只能通过：

```text
BottomNavigationBar / NavigationRail / 明确的程序导航
```

切换。

**普通内容区域不再通过横滑切 Root Tab。**

---

## 2.2 横滑只能表达当前局部语义

允许：

```text
Feed 横滑 → 综合 / 最新 / 精华 / 关注

课表横滑 → 上一周 / 下一周
```

不允许：

```text
Feed 横滑 → 突然跳到集市

课表横滑 → 突然跳到校园
```

---

## 2.3 后台刷新不得破坏阅读

凡是后台触发：

```text
Timer
App resumed
SSE reconciliation
后台 freshness check
```

不得无条件改变：

```text
scroll offset
当前正在阅读的帖子位置
当前 mode
当前输入焦点
```

---

## 2.4 高频可逆操作 optimistic

例如：

```text
点赞
取消点赞
已读
```

允许 optimistic。

但必须：

```text
立即反馈
pending 防连点
失败 rollback / reconcile
跨页面保持一致
```

---

## 2.5 实时优先，Polling 只允许兜底

原则：

```text
Realtime healthy
    ↓
停止 polling

Realtime unavailable
    ↓
启动 fallback polling
```

禁止：

```text
Realtime + polling 长期并行
```

---

# 3. PR 顺序

严格按：

```text
UX-0  Preflight
UX-1  Root Navigation Gesture
UX-2  Feed Direct Interaction + Freshness
UX-3  Chat SSE / Polling Coordination
UX-4  Announcement Priority Semantics
UX-5  Campus Today
UX-6  Course Freshness
UX-7  Feed Card Declutter
```

执行。

其中：

```text
UX-1 / UX-2 / UX-3 = P0
UX-4 / UX-5 / UX-6 = P1
UX-7             = P2
```

禁止一次 PR 全做。

---

# 4. UX-0：执行前 Git 状态保护

## 目标

确保 UX 修改从最新 `MCP` 出发，同时绝不覆盖本地未提交工作。

首先执行：

```bash
git fetch origin

git status --short
git branch --show-current
git rev-parse HEAD
git rev-parse origin/MCP
git log --oneline --decorate -8
```

期望：

```text
origin/MCP
7bdf3a3...
```

如果工作区 dirty：

### 禁止

```bash
git reset --hard
git clean -fd
git checkout -f
git restore .
```

必须先确认 dirty 文件来源。

如果是已有有效工作，先保存到独立 branch / commit。

如果工作区 clean：

```bash
git switch MCP
git pull --ff-only origin MCP
```

之后每项创建独立 branch。

---

# 5. UX-1：Root Navigation Gesture Convergence

**Priority：P0**

建议 branch：

```text
ux/root-navigation-gesture
```

## 5.1 目标

彻底消除：

```text
根导航横滑
vs
Feed mode 横滑
vs
课表 week 横滑
```

三者竞争。

---

## 5.2 修改范围

重点检查：

```text
client/lib/screens/home_screen.dart
client/lib/utils/screen_swipe.dart
client/lib/screens/shuitie_screen.dart
client/lib/screens/course_schedule_screen.dart
client/lib/widgets/bottom_nav.dart
```

---

## 5.3 HomeScreen

删除 root swipe 相关状态：

```text
_navigationSwipePointer
_navigationSwipeIntent
_navigationSwipeStart
_navigationSwipeStartTime
_mainSwipeDx
```

以及：

```text
_startNavigationSwipe
_updateNavigationSwipe
_finishNavigationSwipe
_cancelNavigationSwipe
_canStartMainNavigationSwipe
```

删除包裹整个 Scaffold、只为 Root Swipe 服务的 Pointer Listener。

BottomNav：

```text
onTap → _switchTab()
```

保持原有视觉过渡。

**不要删除 BottomNav 的 indicator motion。**

---

## 5.4 screen_swipe.dart

不要机械地“因为其它文件引用就保留”。

逐一检查：

```text
mainNavigationGestureZoneHeight
mainNavigationRequiresBottomZone
isMainNavigationGestureZone
```

如果所有 callsite 都只是：

> 为 root navigation swipe 预留底部 120 px

则全部删除。

同时删除：

```text
Feed 底部 120px 不允许 mode swipe
Course 底部 120px 不允许 week swipe
```

如果某 helper 还有真正独立语义才能保留，并重命名为该具体语义。

---

## 5.5 保留

必须继续支持：

```text
Feed mode swipe
Course week swipe
页面自身 SwipeToExit（如果属于详情页返回语义）
```

Root swipe 与 page-exit swipe 不是同一个东西。

---

## 5.6 测试

新增或扩展 Widget Test。

至少：

### Case 1

首页内容区域从左向右横滑：

```text
仍停留首页
```

### Case 2

课表中部横滑：

```text
切周
不切 Root Tab
```

### Case 3

课表靠近屏幕底部横滑：

```text
仍可切周
```

### Case 4

Feed 中部横滑：

```text
切 Feed mode
```

### Case 5

Feed 底部横滑：

```text
仍可切 Feed mode
```

### Case 6

BottomNav：

```text
首页 → 集市 → 课表 → 校园 → 我
```

全部正常。

---

# 6. UX-2：Feed Direct Interaction + Freshness

**Priority：P0**

建议 branch：

```text
ux/feed-direct-actions
```

这是整个计划中工作量最大的 PR。

---

# 6.1 统一点赞状态机

不要在 Widget 内：

```text
new Dio
直接 POST
自行维护第二份 liked
```

新增 Provider 级 mutation。

建议：

```dart
Future<LikeMutationResult> toggleLikeOptimistic(Post post)
```

或等价接口。

维护：

```dart
Set<int> _pendingLikePostIds
```

---

## optimistic 流程

例如当前：

```text
isLiked = false
likeCount = 12
```

点击：

```text
立即：
isLiked = true
likeCount = 13

更新：
综合
最新
精华
关注
搜索结果可更新处
详情
```

然后：

```http
POST /posts/:id/like
```

失败：

恢复旧 snapshot。

取消：

```http
DELETE /posts/:id/like
```

---

# 6.2 PostDetail 迁移

当前：

```text
PostDetailScreen._toggleLike()
```

已有独立 optimistic 状态机。

必须迁移到统一 Provider。

最终：

```text
Feed PostCard
      ↓
PostProvider toggleLikeOptimistic

PostDetail
      ↓
同一个 PostProvider toggleLikeOptimistic
```

禁止长期两套并存。

---

# 6.3 服务端状态冲突

考虑双设备：

```text
A 已点赞
B 本地缓存仍显示未点赞
```

B 点击：

```http
POST /like
```

如果服务端返回“已经点赞”等状态冲突：

**禁止直接 rollback 成未点赞。**

发生明确冲突时：

```text
使用服务端返回状态
或
单次 REST reconciliation
```

只处理异常路径。

不要每次点赞都重新请求帖子。

---

# 6.4 PostCard 点击语义

固定：

### 点卡片正文

```text
进入详情
不自动弹键盘
```

### 点点赞

```text
原地点赞
不进入详情
```

### 点评论

```text
进入详情
自动 focus reply composer
弹键盘
```

评论 focus 使用明确的 route argument：

例如：

```dart
PostDetailScreen(
  postId: id,
  focusReplyComposer: true,
)
```

禁止：

```dart
Future.delayed(Duration(milliseconds: 500))
```

猜键盘时机。

---

# 6.5 Freshness Probe

当前 60 秒后台 refresh 改成：

```text
freshness probe
```

而不是：

```text
后台直接替换当前列表
```

---

## 用户正在顶部

例如：

```text
scrollOffset < 小阈值
```

可以温和更新。

---

## 用户已经向下浏览

后台检测到内容变化：

```text
不修改 visible list
```

显示：

```text
┌────────────────┐
│ 内容有更新  ↑   │
└────────────────┘
```

用户点：

```text
应用新 snapshot
scrollToTop
```

---

## “最新”

如果接口可靠判断新增数量，可以：

```text
有 3 条新内容
```

否则：

```text
有新内容
```

不要伪造 N。

---

## 综合 / 精华 / 关注

排序可能变化，因此默认：

```text
内容有更新
```

不要宣称：

```text
有 5 条新帖
```

除非真正能证明。

---

# 6.6 Provider 要求

freshness 逻辑应放 Provider / domain 状态附近。

考虑：

```text
requestVersion
generation
inflight coalescing
modeAtStart
stale response
```

必须保证：

### 快速切 mode

```text
综合请求晚返回
```

不能污染用户已经切到：

```text
最新
```

### optimistic like

不能被旧 snapshot 覆盖回去。

---

# 6.7 手动刷新

Pull-to-refresh：

```text
立即获取并应用
```

因为这是用户显式请求。

自动 refresh：

```text
probe first
```

二者不能混用。

---

# 6.8 UX-2.8：Latest Feed Server-Authoritative Ordering

当前 `_resolveVisiblePosts()`（`client/lib/screens/shuitie_screen.dart`）对「最新」仍做客户端二次过滤：

```dart
if (mode == 'new') {
    // 只保留最近 3 天

    if (recent.isNotEmpty) {
        return recent;
    }

    // 没有最近帖子时只显示 12 条
    return sortedPosts.take(12).toList();
}
```

服务端已经以 `created_at DESC` 返回，客户端又截了一次。

删除 `_resolveVisiblePosts()` 中：

```text
- 最近 3 天过滤
- take(12)
- 客户端 createdAt 再排序
```

「最新」列表完全使用 PostProvider 返回顺序。

理由不是推荐算法，而是：

> 客户端不应该把服务端已有的 Feed 语义重新改一遍。

这属于 UX-2 的 Freshness / state correctness 同类问题。

置顶先不动：「最新」是否定义成彻底无置顶是产品 IA 决策，
当前服务端已明确将 `pinned_posts` 与普通快照分离，等推荐轨 FEED-0 再定。

---

# 7. UX-3：Chat SSE / Polling Coordination

**Priority：P0**

建议 branch：

```text
ux/chat-realtime-fallback
```

注意：

> 这是业务行为修改，不属于 #59 的纯视觉 Chat Pilot。

不要将其伪装成 #59 的“视觉改动”，因为 #59 明确要求 `MessageProvider` 零侵入。

---

# 7.1 Connection State

为 MessageProvider 增加：

```dart
enum MessageRealtimeState {
  disconnected,
  connecting,
  connected,
  reconnecting,
}
```

必要时再额外暴露：

```text
fallbackPolling
```

但不要把 UI 状态和传输层状态混成一个 enum。

---

# 7.2 SSE 生命周期

发起请求：

```text
connecting
```

成功拿到 SSE stream：

```text
connected
```

连接断开：

```text
reconnecting
```

session/logout：

```text
disconnected
```

每次 state 真正变化才：

```text
notifyListeners()
```

避免高频 rebuild。

---

# 7.3 ChatList

现在的：

```text
30 秒 Timer.periodic
```

修改为：

```text
页面可见
AND
SSE != connected
```

才允许 fallback polling。

SSE connected：

```text
cancel timer
```

---

# 7.4 ChatDetail

同样：

```text
SSE connected
→ 不进行 25 / 45 秒固定 polling
```

SSE 断开：

可 fallback：

```text
active conversation：10–15 秒
conversation list：20–30 秒
```

具体值可以复用现有策略，不必为了数字重新设计。

---

# 7.5 页面可见性

需要同时考虑：

```text
AppLifecycle
Route visibility
当前是否 Chat 页面
SSE state
```

最终：

```text
不在私信页
→ 不启动页面级 fallback polling
```

---

# 7.6 Reconnect Reconciliation

SSE 恢复：

```text
connected
↓
执行一次 REST reconciliation
↓
更新：
conversation summary
current conversation
unread count
↓
停止 fallback polling
```

不是持续 REST polling。

---

# 7.7 竞态

必须覆盖：

```text
Local pending message
HTTP Send response
SSE message.created
REST reconciliation
```

四路可能不同顺序返回。

唯一性：

```text
server message.id
+
client_message_id
```

确保最终只有一条。

---

# 7.8 用户提示

短暂 reconnect：

```text
不要显示红色错误 Banner
```

只有：

```text
SSE 持续失败
AND
fallback REST 也失败
```

才显示：

```text
消息暂时无法更新
点击重试
```

禁止给普通用户显示：

```text
SSE disconnected
HTTP 502
event stream broken
```

---

# 8. UX-4：Announcement Priority Semantics

**Priority：P1**

建议 branch：

```text
ux/announcement-priority
```

这是一个小 PR。

---

# 8.1 产品语义固定

建议：

```text
urgent
→ modal

important
→ banner / badge

normal
→ badge / 公告中心
```

只有 urgent 可以主动中断用户。

---

# 8.2 修正 important / modal 歧义

目前客户端候选包含：

```text
urgent
important
```

但服务端：

```text
has_urgent
```

只统计 urgent。

不要保留这种半套语义。

推荐直接：

```text
modal candidate = urgent only
```

并同步 Admin UI 文案。

如果管理员：

```text
priority = important
display_mode = modal
```

应该：

* 自动纠正；
* 禁用组合；
* 或保存时给明确说明。

推荐 Admin 表单层直接禁止无效组合。

---

# 8.3 Alias

```text
/api/notices
/api/announcements
```

是同一资源 alias。

不要做客户端“两个公告源去重系统”。

只保留 fallback 兼容，并加 route consistency test 即可。

---

# 9. UX-5：Campus Today

**Priority：P1**

建议 branch：

```text
ux/campus-today
```

---

# 9.1 IA

Campus 固定定位：

> 校园生活和学习服务聚合首页。

结构建议：

```text
CampusHeader

Today

最新重要资讯

AI

校园服务

校园资讯
```

---

# 9.2 Today

最多显示 3–4 条。

例如：

```text
下一节课
最近考试
重要公告
竞赛截止
```

不是强制每天四种都出现。

---

# 9.3 数据原则

Today 禁止调用 LLM 来生成事实。

必须来源于已有：

```text
CourseScheduleProvider
考试数据
Announcement
Competition calendar
```

---

# 9.4 降级

每个 item 独立降级。

例如课表不可用：

```text
只隐藏“下一节课”
```

不能：

```text
整个 Today error
```

---

# 9.5 性能

禁止：

```text
Campus build
→ 重新拉课表
→ 拉考试
→ 拉公告
→ 拉竞赛
```

形成请求风暴。

优先：

```text
已有 Provider
内存状态
cache
```

需要 freshness 时异步 refresh。

---

# 9.6 跳转

下一节课：

```text
→ 课表
```

考试：

```text
→ 考试
```

公告：

```text
→ 公告详情
```

竞赛：

```text
→ 竞赛详情
```

Today 不是只读装饰卡片。

---

# 10. UX-6：Course Freshness

**Priority：P1**

建议 branch：

```text
ux/course-freshness
```

只做三个问题。

---

# 10.1 上次同步

直接复用：

```text
ScheduleVaultSnapshot.fetchedAt
```

显示例如：

```text
本地课表 · 今天 07:42 已同步
```

较旧：

```text
使用本地课表 · 3 天前同步
```

不要新建数据库字段。

---

# 10.2 回到本周

用户浏览：

```text
第 7 周
```

实际现在：

```text
第 3 周
```

出现明确按钮：

```text
回到本周
```

点击：

```text
pager animate / jump current week
```

尊重：

```text
MediaQuery.disableAnimationsOf(context)
```

---

# 10.3 设置开学日期

当前：

```text
点击“第 N 周”
→ 设置开学日期
```

属于隐藏交互。

修改：

```text
第 N 周
```

主要用于展示。

在：

```text
CourseActionMenu
```

增加明确入口：

```text
设置开学日期
```

必要时标题仍可保留点击快捷方式，但不能成为唯一入口。

---

# 10.4 已有能力禁止修改

不要重新实现：

```text
_isFetchingCourses
失败保留缓存
其它学期拉取
拉取后自动切学期
CourseImportSheet
CoursePreviewSheet
```

---

# 11. UX-7：Feed Card Declutter

**Priority：P2**

建议 branch：

```text
ux/feed-card-declutter
```

必须等 P0/P1 稳定以后做。

---

# 11.1 Feed Card 信息预算

普通帖子 Feed 首屏只高亮：

```text
头像
昵称
必要身份
时间

标题 / 正文
图片

点赞
评论
```

---

# 11.2 降低层级

例如：

```text
浏览量
经验
信用分
复杂身份信息
内部推荐字段
过多 badge
```

如果不是用户判断该帖是否值得读的必要信息：

```text
降低视觉权重
或
移到详情
```

---

# 11.3 保留业务语义

不要为了简洁删除：

```text
置顶
精华
投票状态
二手已售
组队截止
管理员身份等真正必要状态
```

---

# 12. 与现有 GitHub Issues 的边界

## #59 Chat Pilot

继续负责：

```text
Chat UI
composer
发送态
失败态
scroll behavior
motion
golden
```

UX-3 不并入 #59。

---

## #62 Migration

继续负责 design-system 逐模块迁移。

本计划遵守：

> 一次一个用户流程。

不要借 UX PR 顺便“把整个目录迁移完”。

---

## #63 Motion Audit

本计划只复用：

```text
AppMotion
reduced motion
```

不负责完成全项目 motion audit。

---

## #64 A11y

每个 UX PR 的 acceptance matrix 都必须吸收：

```text
touch target
dark mode
large text
reduced motion
```

但不要在一个 UX PR 顺便完成整个全项目 A11y backlog。

---

# 13. 自动测试要求

每个 Flutter PR：

```bash
cd client

dart format --set-exit-if-changed .
flutter analyze
flutter test
```

如果服务端有修改：

```bash
cd server

go test ./...
go build ./...
```

---

# 14. Golden 规则

需要视觉变更时按现有 DESIGN_QA 规则执行。

至少关注：

```text
360×800 light
390×844 light
360×800 dark
360×800 large text
```

但：

```text
Golden → 视觉
Widget Test → 交互
Provider Test → 状态机
Integration / manual → 多页面真实行为
```

不要拿 Golden 代替交互测试。

Canonical baseline 必须遵守项目当前 Linux / CI 约定。

禁止 Windows 随意覆盖 baseline。

---

# 15. 人工验收矩阵

## A. Root Navigation

首页任意区域横滑：

```text
不切集市
```

课表横滑：

```text
只切周
```

Feed 横滑：

```text
只切 mode
```

---

## B. Feed Refresh

用户滚动到 10+ 条之后。

后台数据发生变化。

等待自动检查。

必须：

```text
列表位置不动
```

出现：

```text
内容有更新
```

点以后：

```text
应用新内容
回顶部
```

---

## C. Like

Feed 点：

```text
立即 +1
```

进入详情：

```text
仍然 liked
```

其它 mode 看到同帖：

```text
仍然 liked
```

模拟失败：

```text
恢复原状态
```

---

## D. Comment

正文：

```text
进入详情
键盘不弹
```

评论：

```text
进入详情
composer focus
键盘弹出
```

返回：

```text
Feed 原 scroll offset 保留
```

---

## E. Chat

两台设备。

正常网络：

```text
SSE near realtime
无固定 polling
```

断 SSE：

```text
fallback polling 开始
最终收到消息
```

恢复 SSE：

```text
执行一次 reconciliation
fallback 停止
```

检查：

```text
没有重复消息
没有 unread 乱跳
没有 read receipt 倒退
```

---

## F. Announcement

normal：

```text
不 modal
```

important：

```text
banner / badge
```

urgent：

```text
modal
```

snooze 后：

```text
约定时间内不重复
```

---

## G. Campus

Today：

```text
有数据显示
无数据自然隐藏
一个源失败不影响其它 item
```

所有卡片可进入正确页面。

---

## H. Course

离线启动：

```text
课表仍显示
同步时间显示
```

同步失败：

```text
旧课表保留
```

浏览其它周：

```text
回到本周出现
```

---

# 16. 严格禁止事项

整个计划期间禁止：

### 架构

```text
重写 HomeScreen
重写 ShuitieScreen
重写 MessageProvider
```

必须增量修改。

---

### 网络

禁止：

```text
Widget 内 new Dio
为聊天重新实现 WebSocket
SSE connected 时继续固定 polling
```

---

### 状态

禁止：

```text
网络错误 → 清空缓存
后台 refresh → 瞬间替换用户当前阅读列表
点赞 → 整页重新 fetch
```

---

### 时序

禁止使用：

```dart
Future.delayed(Duration(milliseconds: 300))
Future.delayed(Duration(milliseconds: 500))
```

来“碰运气”等待：

```text
keyboard
layout
route
network state
```

如果确有已有历史 hack，不得借本轮继续扩散；新代码必须使用生命周期、frame callback、controller state 或明确事件。

---

### Scope Creep

UX PR 禁止顺便改：

```text
AI 推荐算法
竞赛推荐算法
管理员业务
数据库大迁移
帖子推荐排序模型
教务协议
```

除非该 PR 的验收无法完成且有直接因果关系。

---

# 17. 每个 PR 给 Coding AI 的固定执行流程

每次只能执行一个 UX 编号。

步骤：

```text
1. fetch origin
2. 确认 MCP 最新
3. 阅读该 UX 章节
4. 阅读相关现有 issue
5. 搜索相关 Provider / API / tests
6. 写出现状状态流
7. 写目标状态流
8. 判断是否已有能力
9. 禁止重复实现
10. 创建独立 branch
11. 先补核心状态/交互测试
12. 最小实现
13. dart format
14. flutter analyze
15. flutter test
16. server tests（如涉及）
17. Golden（如涉及视觉）
18. 执行该 UX 的人工 QA
19. 汇总改动
20. 独立 PR
```

如果代码已经实现计划中的某项：

> **跳过，不重复实现。**

PR 描述写明：

```text
planned:
existing:
changed:
not changed:
tests:
manual QA:
known limitations:
```

---

# 18. 推荐 PR 名称

```text
UX-1
fix(ux): remove root swipe navigation conflicts

UX-2
feat(feed): add direct actions and non-disruptive freshness

UX-3
fix(chat): coordinate realtime SSE and polling fallback

UX-4
fix(announcement): align priority and interruption semantics

UX-5
feat(campus): add today-focused campus summary

UX-6
feat(schedule): surface freshness and current-week recovery

UX-7
refactor(feed): reduce post card information noise
```

---

# 19. Definition of Done

## P0 完成

必须满足：

```text
□ Root Tab 不再横滑误触
□ Feed / Course 局部横滑独立正常
□ Feed 点赞无需进入详情
□ 评论可直接进入输入
□ 自动刷新不打断阅读
□ SSE 正常时页面无固定 polling
□ SSE 失败有 fallback
□ 消息无重复
```

---

## P1 完成

```text
□ 公告 interrupt 语义明确
□ important / urgent 无逻辑矛盾
□ Campus 有 Today
□ Today 不产生请求风暴
□ 课表显示上次同步
□ 非本周有“回到本周”
□ 设置开学日期有显式入口
```

---

## P2 完成

```text
□ Feed 卡片信息层级清晰
□ 没有为了“简洁”丢失必要业务状态
□ Dark / Large Text / Reduced Motion 全部通过
```

---

# 20. 最终执行顺序

不要让 Coding AI 一次读取全文以后自行决定顺序。

明确告诉它：

```text
严格按 UX-0 → UX-1 → UX-2 → UX-3 → UX-4 → UX-5 → UX-6 → UX-7 执行。

一次只做一个 UX 编号。

当前先执行 UX-0 和 UX-1。

UX-1 完成后必须：
1. flutter analyze；
2. flutter test；
3. 完成 Root / Feed / Course 手势人工验收；
4. 汇报实际 diff 与测试结果。

在 UX-1 未通过前禁止进入 UX-2。
```

---

# 21. Parallel Track Conflict Rule（2026-08-10 追加）

MCP 同时存在 UX、Feed Recommendation、Composer 三条开发轨。

1. UX-0 ~ UX-7 为当前主轨。
2. 在 UX-2 合入前：
   - 禁止 Recommendation / Composer 修改 `post_provider.dart`。
3. 在 UX-7 合入前：
   - 禁止 Recommendation 修改 `post_card.dart`；
   - 禁止 Recommendation 修改 `community_post_card.dart`；
   - 禁止 Recommendation 修改 `poll_post_card.dart`（实际路径 `client/lib/widgets/poll/poll_post_card.dart`）；
   - 禁止加入「不感兴趣 / 不看TA」Feed UI；
   - 禁止加入 Feed exposure wrapper。
4. Recommendation 后端允许在 UX-2 后并行开发，但不得修改 UX 当前负责的 Flutter 文件。
5. Composer 在 UX-2 合入后可以并行，但不得修改 Feed Card / Home Feed。
6. 每创建一个新 branch，必须从最新 `origin/MCP` 创建，不允许长期基于旧 feature branch 串联。
7. 两条并行轨同时需要修改同一文件时：
   - 后启动者等待前一 PR merge；
   - rebase 最新 MCP；
   - 再实现；
   - 禁止复制另一 branch 的半成品实现。

## 关键合并门

```text
UX-2 merge → 推荐后端（FEED-0 / FEED-1 / FEED-2）、发帖轨（C-1 / C-2 / C-3）可以开始
UX-7 merge → 推荐 Feed UI（FEED-3）才可以开始
```
