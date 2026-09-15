# 逻辑问题审计报告

**日期**：2026-09-15
**范围**：`server/`（Go）、`client/`（Flutter）、`python-edu-service/`、`python-rag-service/`
**方法**：模式化扫描（错误被忽略 / 并发 / 空值 / 边界 / 时区 / 鉴权 / SQL 拼接）＋ 定点阅读上下文复核。
**可信度约定**：本报告的每一条都回到源码处读过上下文并核对过行号后才收录。审计过程中还出现过若干"行号与代码对不上"的外部线索（例如引用了 `python-edu-service` 里并不存在的 `_inflight` 单飞机制、声称 `routers/auth.py` 会把请求方 IP 落库），这些无法在源码处复现的条目一律未收录，剔除清单见第七节。

**条目统计**：2 条高危、6 条中危、5 条客户端问题、7 条低危；另有 9 组已复核为无问题的点，避免后续重复排查。

---

## 一、总体判断

这个仓库的工程水位明显高于同类校园项目，以下做法都做得比较到位，属于"不该改"的部分：

- `middleware/auth.go:63-146` 的 `AuthMiddleware` 是 **fail-closed**：token 缺失/无效、会话查不到、`token_version` 不符、角色变化、账号不可用、法律同意缺失（hard 模式）全部 `Abort`。
- 路由分组鉴权覆盖完整：`main.go` 里 `user` / `waterMod` / `teamAuth` / `pollsAuth` / `canteenAuth` / `canteenAdmin` / `adminWater` / `internalMCP` 都挂了对应中间件，没有"漏挂"的敏感组。
- 业务算法抽成了纯函数并有单测：`services/canteen_ranking.go`（Bayesian）、`internal/academiccalendar/`（时区与教学周边界）、`internal/academiccalendar/semester_mapping.go`（学期映射，明确拒绝按名称猜测）。
- 校历 JSON 的校验做了 `time.Parse` + `Format` round-trip（`handlers/campus_calendar_handler.go:428-435`），所以下游用字符串比较日期是安全的。
- 分页统一为 `(page-1)*pageSize`，且对 `page < 1`、`pageSize` 上界做了收敛。
- `middleware/idempotency.go` 的幂等重放边界处理得很完整（`Completed` 重放 / `Failed` 409 / `Processing` 轮询 / 过期 409 / 认证拒绝则释放记录）。

因此下面列出的问题里，**没有发现"整类能力缺失"**，主要是**边界条件、失败路径和两处一致的缺口**。

---

## 二、高优先级

### H1 · `python-edu-service`：两个路由完全没有内部鉴权，等于一个未授权的凭据代理

**位置**
- `python-edu-service/routers/spider.py:18`
  ```python
  router = APIRouter(prefix="/api/spider", tags=["爬虫服务"])   # 无 dependencies
  ```
- `python-edu-service/routers/spider.py:59-65` `POST /api/spider/erke`、`:130` `POST /api/spider/erke/login`
- `python-edu-service/routers/erke.py:6,14` `POST /erke/scores`
  ```python
  router = APIRouter(prefix="/erke", tags=["二课服务"])
  @router.post("/scores")
  async def get_erke_scores(req: ErkeLoginRequest):   # 无 Depends
  ```

**对照（同服务其它路由都有鉴权）**
`routers/auth.py:15`、`grades.py:19`、`courses.py:21`、`context_bundle.py:31`、`credit_requirements.py:19`、`academic_situation.py:17` 全部带 `dependencies=[Depends(require_internal_service)]`；`internal_jwc.py:34`、`internal_competition.py:28` 带 `Depends(verify_internal_token)`。只有 `spider.py` 和 `erke.py` 是裸的。

**为什么能被外部触达**
- `main.py:175-179`：非退役模式（`SCHOOL_AUTHORITY_RETIRED=false`）会把 `spider.router`、`erke.router` 直接 `include_router`。
- `config.py:13`：`HOST = os.getenv("HOST", "0.0.0.0")`，端口默认 8081，监听全网卡。
- 另外 `main.py:148-154` 的 `freeze_legacy_secrets` 中间件只匹配 `/api/edu` 前缀，**不覆盖** `/api/spider`、`/erke`，所以这两个入口连"旧凭据写入已冻结"的门禁都绕过了。

**具体风险**
任何人只要能访问该端口，就能 `POST` 一组「学号 + 明文密码」，由服务代为完成 WebVPN 登录、验证码 OCR、二课系统登录，并拿到会话 Cookie（`spider.py:111-120` 把 `crawler.export_cookies()` 直接放进响应体）。这等于对外开放了一个**账号撞库/可用性探测代理**，同时每次调用都会消耗 OCR 与上游配额。Go 侧的 `/api/erke/scores`（`cmd/main.go:2113`）虽然有 `AuthMiddleware`，但它会转发到 Python 的同名能力，直连 Python 端口即可绕过 JWT。

**建议修复**
给这两个 router 加 `dependencies=[Depends(require_internal_service)]`（`services/security.py:13` 已提供，且未配置密钥时返回 503，是 fail-closed 的）；若 `erke` 能力已被 `/api/edu` 链路覆盖，直接删除这两个 router 更干净。

---

### H2 · Go：时区初始化失败只打日志，之后所有按 `time.Local` 计算的"自然日"会静默错 8 小时

**位置**
- `server/cmd/main.go:137-140`
  ```go
  func main() {
      if err := academiccalendar.InitializeTimezone(); err != nil {
          log.Printf("[ACADEMIC_CALENDAR_TIMEZONE_UNAVAILABLE] %v", err)
      }
  ```
- `server/internal/academiccalendar/timezone.go:14-23`：这个函数同时做两件事 —— 设置 `ShanghaiLocation`，**并改写全局 `time.Local = location`**。
- 依赖 `time.Local` 的业务点：
  - `internal/services/exp_award_service.go:36` 与 `:109`：`today := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.Local)`（每日经验发放的唯一键）
  - `internal/handlers/water_section.go:1309`：同上，日榜/日计数
  - `internal/handlers/competition.go:328`：`time.ParseInLocation("2006-01-02", raw, time.Local)`
  - `internal/handlers/competition.go:506`：按月份构造候选日期

**失效链**
`InitializeTimezone()` 失败时把 `ShanghaiLocation` 置 nil（校历相关调用会显式报错、属于 fail-closed），但 **`time.Local` 保持容器默认值（通常是 UTC）**，而 `main.go` 只是打印日志、继续启动。于是所有用 `time.Local` 做"自然日"截断的路径不再报错，而是**静默地按 UTC 计算**：

1. 每日经验/日计数在**北京时间 08:00** 翻页，而不是 00:00 —— 早 8 点前的行为与早 8 点后归入同一天。
2. `ParseInLocation("2006-01-02", "2026-09-15", time.Local)` 在 UTC 下解析成 UTC 午夜，与按上海时区落库的时间比较时会差 8 小时，出现「已过截止时间仍可提交」或「未到截止时间却提前关闭」。

**建议修复**
这条初始化错误应当 fail-fast（`os.Exit`），或至少让依赖它的功能（经验发放、截止时间判定）在时区不可用时 fail-closed。更彻底的修法是**弃用 `time.Local`**，统一走已经存在的 `academiccalendar.RelativeDate` / `TeachingWeekBoundary`（`timezone.go:26-43`），现在仓库里是两套机制并存。

---

## 三、中优先级

### M1 · Go：申诉投票里管理员经验扣减是"读-改-写"，会跨事务丢失更新；且与后台结案逻辑不一致

**位置** — `server/internal/handlers/appeal.go:710-720`
```go
// 管理员经验-3（不低于0）
var admin models.User
if err := tx.First(&admin, appeal.AdminID).Error; err == nil {
    newExp := admin.AdminExp - 3
    if newExp < 0 {
        newExp = 0
    }
    if err := tx.Model(&admin).Update("admin_exp", newExp).Error; err != nil {
        return err
    }
}
```
**对照组** — `server/internal/tasks/appeal_finalizer.go:131-134` 做同一件事时用的是原子表达式：
```go
tx.Model(&models.User{}).Where("id = ?", appeal.AdminID).
    Update("admin_exp", gorm.Expr("CASE WHEN admin_exp >= 3 THEN admin_exp - 3 ELSE 0 END"))
```

**具体风险**
同一管理员的两个申诉并发结案时，两个事务都读到 `admin_exp=10`、都写回 7，正确结果应为 4 —— 扣减丢失一次。事务持有的是 `appeals` 行的锁，并不锁 `users` 行，所以这不是理论风险。另外 `if err == nil` 会**静默跳过**扣减（管理员记录查不到时不报错、不扣分）。

**附带问题**：法定票数下限 `5` 被硬编码在两处（`appeal.go:675`、`appeal_finalizer.go:110`），改阈值容易只改一处。

**建议修复**：统一改成原子 `gorm.Expr`（或对 `users` 行 `SELECT ... FOR UPDATE`）；把 `5` 抽成共享常量。

---

### M2 · Go：社区规则硬门禁的路径白名单漏掉了食堂评价与水帖版块

**位置** — `server/internal/middleware/auth.go:149-169`
```go
for _, prefix := range []string{
    "/api/posts", "/api/replies", "/api/team/",
    "/api/water/team/", "/api/posts/", "/api/market",
} {
    if strings.HasPrefix(path, prefix) {
        return true
    }
}
```
**实际存在但不在白名单里的写接口**
- `cmd/main.go:2363-2377`：`canteenAuth.POST("")`、`POST /:id/rate`、`POST /:id/reviews`、`PATCH /reviews/:reviewId`、`PUT /reviews/:reviewId/vote`
- `cmd/main.go:1642`：`waterMod.POST("/icon-review")`

**具体风险**
`LegalConsentEnforcementHard` 模式下，一个**没有确认社区规则**的用户发不了帖子，却能发食堂评价（同样是带文字和图、会公开展示的用户内容）。同一条内容政策在两个入口执行不一致，合规说明上很难自洽。

**建议修复**：把前缀表补全，或改成按"资源类型"判定；更稳妥的做法是给需要门禁的路由显式挂一个中间件，而不是靠路径前缀猜。

---

### M3 · Go：一批"失败被吞掉 → 仍然返回成功/空数据"的失败模式

这一类不是单点 bug，而是同一个错误处理习惯在多处复现，效果是**接口在出错时依然 200，前端把错误当成了"本来就没有数据"**。

| 位置 | 代码 | 触发后果 |
|---|---|---|
| `handlers/canteen_reviews.go:2160-2169` | `_ = tx.First(&latest, effective.LatestEventID).Error` 之后无条件 `summary.Comment, summary.Images, summary.Tags = latest.Comment, ...` | `First` 失败时 `latest` 为零值，代码不报错，而是把该用户评价摘要里的**评语、图片、标签静默清空** |
| `handlers/canteen_rankings.go:33,39,91,97` | `_ = h.db.Table(...).Scan(&rows).Error` | 查询失败 → `rows` 为空 → 榜单标签、评价数静默变空，接口仍 200 |
| `handlers/user.go:415-416, 471-472, 425, 433` | `h.db...Count(&total)` / `.Find(&follows)` 全部不接错误 | DB 抖动时"关注/粉丝列表"返回 `200 + items: [] + total: 0`，客户端显示成"这个人没有关注任何人" |
| `handlers/feedback_ticket.go:162,169`、`handlers/feedback_ticket_admin.go:162,169` | 附件、状态历史 `Find` 不接错误 | 管理员打开工单可能看到"没有附件、没有变更记录"的残缺详情，且无从察觉 |
| `handlers/feedback_ticket_admin.go:145` | `_ = h.db.Model(&ticket).Updates(updates).Error` | `admin_viewed` 写失败被吞，管理端未读角标长期不消 |

关于第一行需要说明分寸：`effective.LatestEventID` 来自同一事务内的查询结果，**正常路径下 `First` 查得到**，所以它不是一个高频 bug；值得修的原因是失败方向是**破坏性的**（把已有展示内容清空）而不是报错，应当 `return err` 或保留旧值。

**建议修复**：查询类失败要么返回 5xx，要么在响应里带 degraded 标记；"失败即当空"在处理用户可见数据时是最容易掩盖问题的写法。

---

### M4 · Python：成绩分页 `while True` 没有页数上限

**位置** — `python-edu-service/services/crawler.py:794-869`
```python
page_size = 500
page = 1
while True:
    form_data = {..., "queryModel.currentPage": str(page)}
    ...
    items = data.get("items", [])
    all_items.extend(items)
    if len(items) < page_size:
        break
    page += 1
```
**具体风险**
循环终止完全依赖上游"尊重 `currentPage`"。若教务端点在改版/参数名不匹配时对任意页码都返回同一批满 500 条，`len(items) == page_size` 恒成立 → **永不 break**，`all_items` 持续增长，同时持续打上游。这类"上游行为变化"在爬虫里是常态，而不是意外。

**建议修复**：加硬上限（如 `MAX_PAGES`）与累计条数上限，并做 `(page, 首条记录 id)` 重复检测作为额外刹车。

---

### M5 · Go：水帖删帖失败仍然返回 200，且审计日志与作者通知照发

**位置** — `server/internal/handlers/water_moderation.go:640-644`
```go
h.db.Model(&post).Update("status", models.PostStatusDeleted)
h.writeLog(section.ID, operator.ID, models.ModActionDeletePost, "post", uint(postID), &post.AuthorID, reason, ...)
h.notifyTarget(post.AuthorID, operator.ID, models.ModActionDeletePost, *section, post.ID, post.ID, reason)
c.JSON(http.StatusOK, gin.H{"message": "帖子已删除"})
```
**同一文件的反例** — `RestorePost`（`:711-714`）做同一件事时就检查了错误：
```go
if err := h.db.Model(&post).Update("status", models.PostStatusNormal).Error; err != nil {
    c.JSON(http.StatusInternalServerError, gin.H{"error": "恢复帖子失败"})
    return
}
```

**具体风险**
`Update` 失败时（DB 抖动、连接断开），版主看到的是"帖子已删除"，**操作日志里记下了一次并未发生的删除**，作者还会收到"你的帖子被删除"的通知 —— 而帖子其实仍然可见。三件事同时发生了：UI 说谎、审计记录失真、用户被误通知。同一操作在一个文件里两处写法不一致，说明这是遗漏而非有意设计。

**建议修复**：与 `RestorePost` 对齐，检查 `Update(...).Error`，失败返回 500 并且不写日志、不发通知。建议顺带核查本文件其余 `Update/Delete`（`:220`、`:247`、`:324`、`:904` 附近）是否同一模式 —— 我只复核了 `:640` 这一处。

---

### M6 · Go：公开接口无条件下发 `can_delete: true`

**位置** — `server/internal/handlers/canteen_reviews.go:1193-1197`（`GetReviewHistory`）
```go
for i := range events {
    populateReviewPublicFields(h.db, &events[i])
    events[i].CanDelete = true
    events[i].CanEdit = events[i].ScoreVersion >= 2 &&
        events[i].ID == latestEvent.ID && !canteen.IsOffline
}
```
**为什么是问题**
这个 handler 挂在**可选鉴权**的公开路由上（`cmd/main.go:2329`：`canteen.GET("/:id/reviews/history/:userId", middleware.OptionalAuthMiddleware(...), canteenHandler.GetReviewHistory)`），也就是说匿名用户也能读到任意用户的历史评价。而 `CanDelete` 在同一个循环里被**无条件写成 `true`**，旁边的 `CanEdit` 却做了严格的归属与状态判断 —— 同一个响应里两个权限字段的语义不自洽。当前端把这个字段当作"可删除"的展示依据时，会给访客显示自己无权执行的删除入口。

**建议修复**：`events[i].CanDelete = viewerID != 0 && viewerID == userID`（文件中 `viewerID` 在 `:1208` 附近才计算出来，需把该赋值调整到视图者身份确定之后）。

---

## 四、客户端（Flutter）

以下 3 条我回到源码逐行核对过（含调用了哪条路径、哪些重置点可达）。另附 2 条低危。

### C1 · `message_provider`：`_loadingMore` 会永久卡在 true，之后上滑再也拉不到历史消息

**位置** — `client/lib/providers/message_provider.dart`
- `loadOlderMessages`（`:466-516`）取版本号但**不自增**，并把复位放在版本守卫里：
  ```dart
  final requestVersion = _messageRequestVersion;   // :469 读取，不自增
  ...
  } finally {
    if (_ownsSessionRequest(sessionRequest) &&
        requestVersion == _messageRequestVersion) {   // :509-510
      _loadingMore = false;
      notifyListeners();
    }
  ```
- `loadMessages`（`:389`）会 `++_messageRequestVersion`，但它的**缓存未命中分支只重置 4 个字段**（`:413-417`）：
  ```dart
  _messages = [];
  _hasMore = true;
  _messageError = null;
  _messageLoading = true;      // 注意：没有 _loadingMore = false
  ```
  （缓存命中分支 `:396-401` 是有 `_loadingMore = false` 的 —— 两条路径不一致。）

**可达性核查**：全仓 `_loadingMore = false` 的写入点只有 `:220`（`resetSession`，仅由切号 `syncSessionUser` 触发）、`:400`（缓存命中分支）、`:511`（受版本守卫）、`:1274`（`prepareNewConversation`）、`:1285`（`clearMessages`，**全仓无调用点**，已 grep 确认）。而 `chat_detail_screen.dart:415` 打开会话时传的是 `preferCache: true`，但缓存里没有该会话时仍会走 `:413-417`。

**触发**：在会话 A 上滑加载更早消息（请求在途）→ 立刻打开一个本次会话尚未缓存的会话 B（`loadMessages` 走到 `:413-417`，版本 +1）→ A 的响应回来时 `finally` 的版本守卫不成立、被跳过 → `_loadingMore` 永久为 true。

**后果**：`:475-478` 的守卫 `if (conversationId == null || _loadingMore || !_hasMore || oldestMessageId == null) return;` 从此对所有会话短路，**上滑加载历史消息静默失效，没有任何报错**，直到发生切号或走到其他重置路径。

**建议修复**：在 `loadMessages` 的非缓存分支（`:413-417`）一并重置 `_loadingMore = false;`，或把 `finally` 里的复位改为无条件（仅 `notifyListeners()` 保留在版本守卫内）。

### C2 · `post_provider`：刷新与翻页共用版本号且刷新不置 loading，会整页跳过

**位置** — `client/lib/providers/post_provider.dart`
- 翻页 `:806-811` 取版本号但**不自增**，且守卫只看 `isLoading`：
  ```dart
  if (board.isLoading || !board.hasMore) return;
  board.isLoading = true;
  ...
  final requestVersion = board.requestVersion;   // :809 读取，不自增
  ```
- 刷新 `_refreshInternal`（`:947`）是 `++board.requestVersion`，但**只在列表为空时才置 loading**（`:954-958`）：
  ```dart
  final requestVersion = ++board.requestVersion;
  board.currentPage = 1;
  ...
  if (board.posts.isEmpty) { board.isLoading = true; ... }
  ```
- 翻页响应回来后的判定用了 `await` 之后的值：
  ```dart
  if (requestVersion != board.requestVersion) return;   // :831
  ...
  if (board.currentPage == 1) { board.posts = newPosts; } else { ...合并... }   // :841
  if (!usesSnapshot) { board.currentPage++; }           // :861
  ```

**触发**：列表非空时的刷新（`:954` 不置 `isLoading`）在途，同时用户滑到底触发 `loadPosts`（`:806` 守卫拦不住）→ 翻页捕获到的版本号与刷新相同 → `:831` 判定相等、响应不被丢弃 → 刷新已把 `currentPage` 重排到 2 并把列表整体替换为第一页 → 翻页响应进入 `else` 合并分支并再 `currentPage++` → 变成 3。

**后果**：**第 2 页被整页跳过**（用户滚动时列表中段帖子缺失），`hasMore` 也基于错位的总数计算。

**建议修复**：`_loadPostsInternal` 改为 `final requestVersion = ++board.requestVersion;`，并用**发起请求时捕获的 `page`** 决定覆盖/合并，而不是事后读 `board.currentPage`。

### C3 · AI 本地会话历史：一条坏记录会让整段历史读成空

**位置** — `client/lib/features/ai_runtime/personal_session/personal_conversation_store.dart`
```dart
static PersonalConversationEntry fromJson(Map<String, dynamic> json) {
  final role = AiMessageRole.values.firstWhere(
    (item) => item.name == json['role'],      // :52-54 无 orElse，未知枚举值抛 StateError
  );
  final status = AiMessageStatus.values.firstWhere(
    (item) => item.name == json['status'],    // :55-57 同上
  );
  final createdAt = DateTime.parse(json['created_at'] as String);   // :58 非 tryParse
```
而同文件对损坏子项的处理是逐条兜底的（`:64-88`），注释写得很清楚：
```dart
} catch (_) {
  // 单个旧草稿损坏时保留其余会话内容，避免整段历史无法恢复。
}
```
**问题**：这个"单条坏、别全丢"的意图**没有应用到 `role`/`status`/`created_at`** —— 它们在 `fromJson` 里裸奔，而 `read()`（`:144-165`）用一个大 try/catch 包住整个 entries 映射，catch 里直接 `return const <PersonalConversationEntry>[];`。

**触发**：降级运行（新版写入过新枚举值后回退旧版）、或本地加密 JSON 单条被截断 → `StateError`/`FormatException` → **整段 AI 本地历史读成空**，随后的 `replace()` 还会用空列表覆盖存档，不可恢复。

**建议修复**：`firstWhere` 加 `orElse`、`DateTime.tryParse`，并把单条 `fromJson` 放进逐条 try/catch 跳过坏记录（与同文件草稿的处理保持一致）。

### C4（低）· `water_section_provider.dart:128` 兜底路径的裸 `firstWhere`
```dart
final campusLife =
    kWaterPostCategories.firstWhere((c) => c.value == 'campus_life');
```
常量表目前含该项，属"未来重构删项/改名就会在构建期抛 StateError"的隐患。建议加 `orElse`。

### C5（低）· 一组无保护的 `int.parse`
`widgets/edu_grade/grade_manage_drawer.dart:477`、`screens/physical_test_screen.dart:501` 与 `:524`、`screens/edu_grade_screen.dart:327-329`、`utils/campus_today.dart:143-144`、`services/unified_timeline_service.dart:243-244`、`services/course_reminder_service.dart:405-406`。学年/时间串来自教务或本地存储，脏数据（`"2023-2024"`、`"8:00 AM"`、`"上午"`）会抛 `FormatException`，其中部分发生在 `build` 期间。建议统一 `int.tryParse` + 默认值。

---

## 五、低优先级 / 加固

- **L1 课表去重键漏字段** — `python-edu-service/services/crawler.py:617-630`
  ```python
  key = (course.name, course.week_day, course.time)
  if key not in seen:
  ```
  键里没有老师、地点、周次。同一门课"1-8 周在 A 教室 / 9-16 周在 B 教室"或不同老师的两行，`(kcmc, xqj, jc)` 相同，第二行会被当成重复丢弃，学生课表少一节。建议把 `week_str`、`teacher` 纳入键，或改为按教学班去重后合并周次。

- **L2 总评回退取"最后一行"** — `python-edu-service/services/crawler.py:1191-1195`
  ```python
  def _find_total_grade(components: List[dict]) -> str:
      for component in components:
          if "总" in component.get("name", ""):
              return component.get("score", "")
      return components[-1]["score"] if components else ""
  ```
  明细表没有名字含"总"的项时，直接把最后一行当总评返回。若最后一行是"平时成绩"，用户会在成绩详情里看到错误的"总评"。建议返回空值并在上层标为 unknown。

- **L3 二课登录同时提交明文密码** — `python-edu-service/erke_crawler.py:427-439`
  ```python
  post_data = {
      ...
      "UserName": username,
      "Password": password,        # 明文
      "pwd":      pwd_encrypted,   # RSA 加密结果
  ```
  第 420 行刚用 `pub_key` 加密出 `pwd`，却又把明文一并提交，加密形同虚设，且明文会进入上游/中间设备的表单日志。建议删除 `Password` 字段（或传空串）。

- **L4 忽略 `ShouldBindJSON` 错误** — `server/internal/handlers/competition.go:2043, 2132, 2149`
  - `:2043` `PinCalendarItem`：body 畸形时 `input.IsPinned` 保持 `false` → 用户以为在置顶，实际把置顶**静默取消**了。
  - `:2132/:2149`：`ShareCode` 为空会落到"分享码不存在"分支；`:2149` 之后还依赖 `input.Strategy` 判合法值，畸形 body 会返回"导入策略只能是 replace 或 merge"，错误提示误导。
  - 修复：按同文件 `:2063` 的写法检查 `err` 并返回 400。

- **L5 `gorm.ErrRecordNotFound` 用 `==` 而非 `errors.Is`** — `server/internal/services/water_permission_service.go:47`、`server/internal/tasks/appeal_finalizer.go:213`
  仓库其它地方（如 `handlers/canteen_reviews.go:2075,2082`）统一用 `errors.Is`。这里一旦错误被包装就会退化成"当成真实错误"（`water_permission_service.go:47` 会返回 err，调用方 `GetPermission` 走 fail-closed —— 安全，但那次权限查询整体失败）。建议统一。

- **L6 RAG 服务令牌用非常量时间比较** — `python-rag-service/app/main.py:234-238`
  ```python
  if not SERVICE_TOKEN or x_internal_service_token != SERVICE_TOKEN:
  ```
  fail-closed 的逻辑是对的，但比较方式与同仓库不一致：`python-edu-service` 的等价实现用了 `hmac.compare_digest`（`dependencies/internal_auth.py:60`、`services/security.py:19`）。建议对齐。

- **L7 本地脚本打印凭据片段** — `python-edu-service/test_erke.py:180` 打印 VPN ticket 前 40 字符；`test_local.py:34` 打印 Cookie 前 60 字符。属手动调试脚本，建议改为只打印长度或哈希。

---

## 六、已复核为「无问题」的点（避免下次重复排查）

- `middleware/auth.go:63-146` `AuthMiddleware`：fail-closed，无绕过分支。
- `cmd/main.go` 路由组鉴权覆盖完整，`internalMCP`（`main.go:1530-1531`）挂了 `InternalMCPGrantOrScopedGrantMiddleware`。
- SQL 列拼接不是注入：`handlers/canteen.go:879-884` 的 `nonNegativeCountExpr` 与 `handlers/water_section.go:390-400` 的 `tagValueExists`，其 `column` 实参全部是常量（`canteen.go:822,825`、`canteen_reviews.go:601,604`、`water_section.go:973,985,1065`）。
- `internal/academiccalendar/semester_mapping.go:46` 的日期字符串比较安全：上游 `handlers/campus_calendar_handler.go:428-435` 已强制 `YYYY-MM-DD` 零填充格式。
- 分页一致：抽查 `competition.go:741,940`、`exam_paper.go:409,1110`、`search.go:109`、`feedback_ticket*.go`，均为 `(page-1)*pageSize`。
- 客户端：`message_provider.dart:722` 的 `firstWhere` 带 `orElse`；`course_schedule_provider.dart:1297-1310` 的 `periodLabels.single` 在 `_canMergeGraduatePair`（`:1278-1288`）有 `length != 1` 前置守卫；`utils/team_share_link.dart` 与 `app_bootstrap.dart:1796-1808` 的深链解析是白名单式（固定 scheme/host/段数 + 正整数校验）；`services/retry_interceptor.dart` 的重试次数有上限（`extra` 记 attempt）且只对 GET/HEAD 生效。
- `python-edu-service` 的凭据静态加密（AES-256-GCM，`services/security.py:34-59`）、JWC/Competition 抓取的 CST 时区使用，均未发现 naive/aware 混比。
- `middleware/idempotency.go` 的幂等重放是本仓库写得最扎实的一段：`replayIdempotentResponse`（`:224-286`）对 `Completed` 才重放存储响应，`Failed` 返回 409 `idempotency_request_failed`，`Processing` 轮询到 deadline 后返回 409 `idempotency_request_in_progress`，过期返回 409 `idempotency_request_expired`，并处理了"认证门禁拒绝则释放记录"（`:136-142`）。**不存在"冲突分支无条件返回 200"的问题**。
- `handlers/teacher.go:462` 的 `VoteRemoveAdmin` **不是 fail-open**：目标不存在或角色不是 `admin` 时直接 400。唯一可议之处是 `super_admin` 无法通过该接口被罢免（`admin.Role != models.RoleAdmin` 的提示语是"目标不是普通管理员"，看起来是有意为之），以及 `votes > totalAdmins/2` 在小规模管理团队下阈值退化为 1 票（`totalAdmins` 已排除目标本人）—— 属多数决规则的固有性质，不作为缺陷计入。

---

## 七、审计过程中被丢弃的线索（重要，供后续审计参考）

并行深审产出了若干**无法在源码处复现**的条目，已全部剔除。保留两个具体例子，因为它们揭示了这类审计的典型失效方式：

| 被丢弃的说法 | 复核结果 |
|---|---|
| "`water_section.go:560` 的 `CanViewSection` 让成员能绕过版块内容可见状态门禁" | `server/internal` 全仓 grep **不存在 `CanViewSection`**；`water_section.go:560` 实际是 `fillLevels` 里的 `WaterSectionUserStat` 批量查询 |
| "`python-edu-service` 的 `crawler.py:1349` 单飞 `_inflight` 未清理" | 全目录 grep `inflight\|in_flight\|singleflight` **零匹配**，该机制不存在 |
| "`routers/auth.py` 会把请求方 IP 落库" | grep `client.host\|request.client\|logged_in_ip` **零匹配** |
| "`jwc_public_crawler.py:494` 用 `requests.get(...).json()` 且无超时" | 该文件用 `httpx`，且 `:721` 有 `timeout=httpx.Timeout(self.timeout)` |

**结论**：这批深审的有效条目都集中在"错误被丢弃 / 竞态 / 状态字段语义"这几类**能从代码结构直接读出来**的问题上；凡是涉及"某处缺少守卫""某个机制没做清理"的否定式断言，误报率明显偏高。后续做同类审计时，否定式结论必须配一条能复现的 grep 或运行证据。

---

## 八、本次尚未覆盖的区域

以下区域本轮没有做深度语义审查，若要继续，建议单独排期：

- `server/internal/ai/`：策略/权限执行链（`permission.go`、`execution_policy.go`、`scoped_grant.go`、`tool_registry.go`、`runtime.go`）与 MCP 工具循环 —— 这是全仓最复杂、也最值得单独审的一块。
- `client/lib/screens/` 的巨型页面主体：`course_schedule_screen.dart`（约 4400 行）、`post_detail_screen.dart`、`competition_center_screen.dart`（约 3200 行）只抽读了片段。
- `client/lib/features/academic/application/academic_session_controller.dart` 的状态机全局迁移。
- 数据库层：索引与唯一约束是否覆盖所有并发写路径（本轮只抽看了 `models/report.go:79-89`、`models/canteen.go:142`、`models/ai_runtime.go` 等少量模型）。
