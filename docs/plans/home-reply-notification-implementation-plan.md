# 首页互动回复提醒实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将当前只能在帖子详情页发现的未读回复提醒前移到首页“水帖”信息流，并保证详情页不再重复展示未读提示。

**Architecture:** 服务端新增认证用户专属的未读回复摘要接口，查询时一次批量加载发送者和帖子标题。客户端用独立的回复通知服务承载摘要查询与单条已读消费；首页当前排序模式均渲染轻量提醒模块，多条提醒通过未读列表选择，点击前先取得原帖，详情页继续使用现有 `targetReplyId` 定位。帖子详情页移除旧的未读查询、横幅、BottomSheet 和“全部已读”路径。

**Tech Stack:** Go、Gin、GORM、SQLite handler tests；Flutter 3.41.8、Dio、Provider、Material、flutter_test Golden helpers。

---

## 文件结构

**服务端**

- Modify: `server/internal/handlers/notification.go`，新增 `GET /notifications/replies/unread` handler；使用认证上下文中的 `user_id`，批量读取 `User` 与 `Post`，保留旧帖子级接口以兼容旧客户端。
- Modify: `server/cmd/main.go:1223-1227`，注册实际客户端使用的 `/api/notifications/replies/unread`；在兼容的 `/api/user` 通知路由中同步注册同一路径。
- Modify: `server/internal/handlers/notification_test.go`，覆盖用户隔离、类型/已读过滤、总数、降序、limit 和发送者/帖子标题映射。

**客户端**

- Modify: `client/lib/models/unread_reply_notification.dart`，增加 `postTitle`，并新增分页响应模型。
- Create: `client/lib/services/reply_notification_service.dart`，封装首页未读回复查询和单条已读请求，不把逻辑塞入 `PostProvider`。
- Create: `client/lib/widgets/reply_notification_reminder.dart`，提供首页摘要模块和多条未读列表 BottomSheet；只使用现有颜色、间距、圆角和 Material 按压反馈。
- Modify: `client/lib/screens/shuitie_screen.dart:118-232, 494-527, 937-968, 1920-2160`，管理加载、登录切换、前台恢复、下拉刷新、单条/多条跳转和删除反馈；在当前首页排序模式有未读时插入模块。
- Modify: `client/lib/screens/post_detail_screen.dart:184-220, 263-300, 2290-2320, 2910-2930, 5577-5795`，移除详情页未读通知状态、请求和 UI，保留 `targetReplyId` 定位；目标回复 404 时仍给出删除反馈。

**测试**

- Create: `client/test/services/reply_notification_service_test.dart`，用 Dio interceptor 验证路径、limit、JSON 映射和单条已读 payload。
- Create: `client/test/widgets/reply_notification_reminder_test.dart`，验证单条/多条语义标签、触控区域、列表选择和 1.3 倍文字无溢出。
- Modify: `client/test/shuitie_feed_state_test.dart`，补充登录用户的最新信息流提醒、空态、失败隐藏和点击消费测试夹具。
- Modify: `client/test/screens/post_detail_target_reply_test.dart`，验证详情页不再请求帖子级未读接口且不渲染未读横幅；保留已有 `targetReplyId` 深链测试。
- Create: `client/test/goldens/home_reply_notification_golden_test.dart`，覆盖浅色、深色、1.3 倍文字的提醒模块 focused region Goldens。
- Create: `client/test/goldens/baselines/home/reply_notification_reminder_light_390x844.png`、`reply_notification_reminder_dark_360x800.png`、`reply_notification_reminder_large_360x800.png`，只在 Linux canonical 环境生成，不在 Windows 更新基线。

## 实施任务

### Task 1: 先锁定服务端未读回复接口合同

**Files:**
- Modify: `server/internal/handlers/notification_test.go`

- [ ] **Step 1: 写失败测试，验证接口返回总数和最新一页。**

在现有测试文件中追加以下测试。测试数据库必须迁移 `Notification`、`User`、`Post`；用户密码字段填充非空值，避免 SQLite 的 `not null` 约束干扰测试。

```go
func TestGetUnreadReplyNotifications(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("打开测试数据库失败: %v", err)
	}
	if err := db.AutoMigrate(&models.Notification{}, &models.User{}, &models.Post{}); err != nil {
		t.Fatalf("迁移通知测试表失败: %v", err)
	}
	createdAt := time.Date(2026, 8, 18, 10, 0, 0, 0, time.UTC)
	if err := db.Create(&[]models.User{
		{ID: 1, Nickname: "收件人", PasswordHash: "hash"},
		{ID: 2, Nickname: "回复者A", PasswordHash: "hash"},
		{ID: 3, Nickname: "回复者B", PasswordHash: "hash"},
	}).Error; err != nil {
		t.Fatalf("写入用户失败: %v", err)
	}
	if err := db.Create(&models.Post{ID: 100, Title: "我的水帖", BoardID: models.BoardShuitie, AuthorID: 1}).Error; err != nil {
		t.Fatalf("写入帖子失败: %v", err)
	}
	if err := db.Create(&[]models.Notification{
		{ID: 10, UserID: 1, Type: "reply", PostID: 100, RelatedID: 501, FromUID: 2, Content: "较早回复", CreatedAt: createdAt},
		{ID: 11, UserID: 1, Type: "reply", PostID: 100, RelatedID: 502, FromUID: 3, Content: "最新回复", CreatedAt: createdAt.Add(time.Minute)},
		{ID: 12, UserID: 1, Type: "reply", PostID: 100, RelatedID: 503, FromUID: 2, Content: "已读回复", IsRead: true, CreatedAt: createdAt.Add(2 * time.Minute)},
		{ID: 13, UserID: 1, Type: "like", PostID: 100, RelatedID: 504, FromUID: 3, Content: "点赞", CreatedAt: createdAt.Add(3 * time.Minute)},
		{ID: 14, UserID: 2, Type: "reply", PostID: 100, RelatedID: 505, FromUID: 1, Content: "其他用户", CreatedAt: createdAt.Add(4 * time.Minute)},
	}).Error; err != nil {
		t.Fatalf("写入通知失败: %v", err)
	}

	gin.SetMode(gin.TestMode)
	recorder := httptest.NewRecorder()
	ctx, _ := gin.CreateTestContext(recorder)
	ctx.Request = httptest.NewRequest(http.MethodGet, "/notifications/replies/unread?limit=1", nil)
	ctx.Set("user_id", uint(1))
	NewNotificationHandler(db).GetUnreadReplyNotifications(ctx)

	if recorder.Code != http.StatusOK {
		t.Fatalf("接口状态码=%d，响应=%s", recorder.Code, recorder.Body.String())
	}
	var response struct {
		Count int `json:"count"`
		Items []struct {
			ID        uint `json:"id"`
			PostID    uint `json:"post_id"`
			RelatedID uint `json:"related_id"`
			Content   string `json:"content"`
			PostTitle string `json:"post_title"`
			FromUser  struct {
				ID       uint   `json:"id"`
				Nickname string `json:"nickname"`
			} `json:"from_user"`
		} `json:"items"`
	}
	if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil {
		t.Fatalf("解析接口响应失败: %v", err)
	}
	if response.Count != 2 || len(response.Items) != 1 {
		t.Fatalf("count/items=%d/%d，期望=2/1", response.Count, len(response.Items))
	}
	item := response.Items[0]
	if item.ID != 11 || item.PostID != 100 || item.RelatedID != 502 ||
		item.Content != "最新回复" || item.PostTitle != "我的水帖" ||
		item.FromUser.ID != 3 || item.FromUser.Nickname != "回复者B" {
		t.Fatalf("最新回复映射错误: %+v", item)
	}
}
```

补充 `encoding/json` 已有导入，并加入 `time` 导入。

- [ ] **Step 2: 运行测试确认 handler 尚不存在。**

运行：`go test ./internal/handlers -run TestGetUnreadReplyNotifications -count=1`

预期：FAIL，提示 `GetUnreadReplyNotifications` 未定义。

- [ ] **Step 3: 实现批量查询 handler。**

在 `GetPostUnreadReplyNotifications` 前加入以下常量、响应类型和方法；使用 `strconv.Atoi` 解析 limit，缺省为 20，负数/非法值回退到 20，大于 20 时截断为 20。

```go
const unreadReplyNotificationLimit = 20

type notificationUserInfo struct {
	ID       uint   `json:"id"`
	Nickname string `json:"nickname"`
	Avatar   string `json:"avatar"`
}

type unreadReplyNotificationItem struct {
	ID        uint                  `json:"id"`
	PostID    uint                  `json:"post_id"`
	RelatedID uint                  `json:"related_id"`
	Content   string                `json:"content"`
	CreatedAt time.Time             `json:"created_at"`
	FromUser  *notificationUserInfo `json:"from_user"`
	PostTitle string                `json:"post_title"`
}

func (h *NotificationHandler) GetUnreadReplyNotifications(c *gin.Context) {
	userID, _ := c.Get("user_id")
	uid := userID.(uint)
	limit := unreadReplyNotificationLimit
	if raw := c.Query("limit"); raw != "" {
		if parsed, err := strconv.Atoi(raw); err == nil && parsed > 0 {
			if parsed < limit {
				limit = parsed
			}
		}
	}

	base := h.db.Model(&models.Notification{}).
		Where("user_id = ? AND type = ? AND is_read = ?", uid, "reply", false)
	var count int64
	if err := base.Count(&count).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取未读回复失败"})
		return
	}
	var notifications []models.Notification
	if err := base.Order("created_at DESC").Limit(limit).Find(&notifications).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取未读回复失败"})
		return
	}

	postIDs := make([]uint, 0, len(notifications))
	fromUIDs := make([]uint, 0, len(notifications))
	for _, notification := range notifications {
		if notification.PostID > 0 {
			postIDs = append(postIDs, notification.PostID)
		}
		if notification.FromUID > 0 {
			fromUIDs = append(fromUIDs, notification.FromUID)
		}
	}

	posts := make(map[uint]models.Post, len(postIDs))
	if len(postIDs) > 0 {
		var records []models.Post
		if err := h.db.Where("id IN ?", postIDs).Select("id, title").Find(&records).Error; err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "获取回复帖子失败"})
			return
		}
		for _, post := range records {
			posts[post.ID] = post
		}
	}
	users := make(map[uint]models.User, len(fromUIDs))
	if len(fromUIDs) > 0 {
		var records []models.User
		if err := h.db.Where("id IN ?", fromUIDs).
			Select("id, nickname, avatar").Find(&records).Error; err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "获取回复发送者失败"})
			return
		}
		for _, user := range records {
			users[user.ID] = user
		}
	}

	items := make([]unreadReplyNotificationItem, 0, len(notifications))
	for _, notification := range notifications {
		item := unreadReplyNotificationItem{
			ID: notification.ID, PostID: notification.PostID,
			RelatedID: notification.RelatedID, Content: notification.Content,
			CreatedAt: notification.CreatedAt,
		}
		if post, ok := posts[notification.PostID]; ok {
			item.PostTitle = post.Title
		}
		if user, ok := users[notification.FromUID]; ok {
			item.FromUser = &notificationUserInfo{
				ID: user.ID, Nickname: user.Nickname, Avatar: user.Avatar,
			}
		}
		items = append(items, item)
	}
	c.JSON(http.StatusOK, gin.H{"count": count, "items": items})
}
```

新增 `strconv` 导入。查询中的 `user_id` 始终来自认证 middleware，不读取 query/body 中的用户 ID；`posts` 和 `users` 均为批量查询，禁止在通知循环中调用 `First`。

- [ ] **Step 4: 运行测试确认合同通过。**

运行：`gofmt -w server/internal/handlers/notification.go server/internal/handlers/notification_test.go`；随后运行 `go test ./internal/handlers -run TestGetUnreadReplyNotifications -count=1`。

预期：PASS；响应 `count=2`、`items` 只有最新一条，已读、非 reply 和其他用户数据均被排除。

- [ ] **Step 5: 提交服务端合同测试。**

```bash
git add server/internal/handlers/notification_test.go
git commit -m "test: define unread reply notification contract"
```

### Task 2: 暴露 API 并完成服务端实现

**Files:**
- Modify: `server/internal/handlers/notification.go`
- Modify: `server/cmd/main.go:1128-1132,1223-1227`
- Test: `server/internal/handlers/notification_test.go`

- [ ] **Step 1: 注册实际客户端和兼容路径。**

在 `/api/notifications` 路由组中加入：

```go
r.GET("/api/notifications/replies/unread",
	middleware.AuthMiddleware(db, cfg.JWTSecret),
	notificationHandler.GetUnreadReplyNotifications)
```

在现有 `user` 兼容通知路由中加入：

```go
user.GET("/notifications/replies/unread", notificationHandler.GetUnreadReplyNotifications)
```

旧的 `postsAuth.GET("/:id/notifications/unread", ...)` 暂时保留给旧客户端；新客户端不得继续调用它。

- [ ] **Step 2: 增加路由层回归断言并运行服务端全量测试。**

若现有路由测试可复用认证 helper，则使用真实 `/api/notifications/replies/unread?limit=20` 路径验证 200；否则保留 handler 直接调用测试，并用 `rg -n "/api/notifications/replies/unread" server/cmd/main.go` 作为静态注册检查。

运行：`go test ./...`

预期：PASS，且在 `server` 目录运行 `gofmt -d internal/handlers/notification.go cmd/main.go` 无输出。

- [ ] **Step 3: 提交服务端实现。**

```bash
git add server/internal/handlers/notification.go server/cmd/main.go
git commit -m "feat: expose unread reply notification feed"
```

### Task 3: 建立客户端模型和通知服务

**Files:**
- Modify: `client/lib/models/unread_reply_notification.dart`
- Create: `client/lib/services/reply_notification_service.dart`
- Create: `client/test/services/reply_notification_service_test.dart`

- [ ] **Step 1: 写失败的 Dio contract test。**

测试必须断言请求路径为 `/notifications/replies/unread`、query `limit=20`，并断言 `post_title`、发送者资料、`count` 正确映射；第二个用例断言已读请求只提交一个 ID。

```dart
test('查询未读回复摘要并映射帖子标题', () async {
  final dio = Dio();
  dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
    expect(options.path, '/notifications/replies/unread');
    expect(options.queryParameters['limit'], 20);
    handler.resolve(Response(
      requestOptions: options,
      statusCode: 200,
      data: {
        'count': 2,
        'items': [
          {
            'id': 11,
            'post_id': 100,
            'related_id': 502,
            'content': '最新回复',
            'post_title': '我的水帖',
            'created_at': '2026-08-18T10:01:00Z',
            'from_user': {'id': 3, 'nickname': '回复者B', 'avatar': ''},
          },
        ],
      },
    ));
  }));

  final result = await ReplyNotificationService(dio).fetchUnread();
  expect(result.count, 2);
  expect(result.items.single.postTitle, '我的水帖');
  expect(result.items.single.fromUser?.nickname, '回复者B');
});

test('单条已读只提交选中的通知 ID', () async {
  final dio = Dio();
  dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
    expect(options.path, '/notifications/read-selected');
    expect(options.data, {'ids': [11]});
    handler.resolve(Response(requestOptions: options, statusCode: 200));
  }));

  await ReplyNotificationService(dio).markRead(11);
});
```

- [ ] **Step 2: 运行测试确认模型和服务尚不存在。**

运行：`cd client; flutter test test/services/reply_notification_service_test.dart`

预期：FAIL，提示服务类或响应类型未定义。

- [ ] **Step 3: 扩展模型并实现服务。**

`UnreadReplyNotification` 增加 `postTitle` 字段；用 `num`/`toInt()` 兼容服务端数值类型，用空字符串兼容历史通知缺少标题的情况。新增服务完整接口：

```dart
class UnreadReplyNotificationPage {
  final int count;
  final List<UnreadReplyNotification> items;

  const UnreadReplyNotificationPage({required this.count, required this.items});

  factory UnreadReplyNotificationPage.fromJson(Map<String, dynamic> json) {
    final rawItems = (json['items'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(UnreadReplyNotification.fromJson)
        .toList(growable: false);
    return UnreadReplyNotificationPage(
      count: (json['count'] as num?)?.toInt() ?? rawItems.length,
      items: rawItems,
    );
  }
}

class ReplyNotificationService {
  final Dio _dio;

  const ReplyNotificationService(this._dio);

  Future<UnreadReplyNotificationPage> fetchUnread({int limit = 20}) async {
    final safeLimit = limit.clamp(1, 20).toInt();
    final response = await _dio.get(
      '/notifications/replies/unread',
      queryParameters: {'limit': safeLimit},
    );
    final data = response.data;
    if (response.statusCode != 200 || data is! Map<String, dynamic>) {
      throw StateError('未读回复响应格式错误');
    }
    return UnreadReplyNotificationPage.fromJson(data);
  }

  Future<void> markRead(int notificationId) async {
    await _dio.post(
      '/notifications/read-selected',
      data: {'ids': [notificationId]},
    );
  }
}
```

文件中的新增注释使用中文，服务不缓存、不本地标记已读，失败直接向页面抛出异常。

- [ ] **Step 4: 运行服务测试并格式化。**

运行：`cd client; dart format lib/models/unread_reply_notification.dart lib/services/reply_notification_service.dart test/services/reply_notification_service_test.dart; flutter test test/services/reply_notification_service_test.dart`

预期：PASS；Dio 请求路径和 payload 与服务端合同一致。

- [ ] **Step 5: 提交客户端数据层。**

```bash
git add client/lib/models/unread_reply_notification.dart client/lib/services/reply_notification_service.dart client/test/services/reply_notification_service_test.dart
git commit -m "feat: add unread reply notification service"
```

### Task 4: 实现首页提醒模块和多条列表

**Files:**
- Create: `client/lib/widgets/reply_notification_reminder.dart`
- Modify: `client/lib/screens/shuitie_screen.dart:118-232,494-527,937-968,1920-2160`
- Create: `client/test/widgets/reply_notification_reminder_test.dart`
- Modify: `client/test/shuitie_feed_state_test.dart`

- [ ] **Step 1: 先为提醒组件写失败的状态和无障碍测试。**

测试文件补充 `models/user.dart`、`models/unread_reply_notification.dart` 和提醒组件 import；fixture 创建两个 `UnreadReplyNotification`，一条的 `postTitle` 为“我的水帖”、发送者为“回复者B”，另一条标题为“第二篇帖子”。断言：

```dart
UnreadReplyNotification _notification(int id, String postTitle) {
  return UnreadReplyNotification(
    id: id,
    postId: 100,
    relatedId: id + 500,
    content: '这是一条用于测试的回复内容',
    postTitle: postTitle,
    createdAt: DateTime.utc(2026, 8, 18, 10),
    fromUser: User(
      id: 3,
      studentId: 'reply-author',
      nickname: '回复者B',
      avatar: '',
      createdAt: DateTime.utc(2026, 1, 1),
    ),
  );
}

Widget _testApp(Widget child) {
  return MaterialApp(home: Scaffold(body: Center(child: child)));
}

testWidgets('单条摘要显示内容并提供完整语义', (tester) async {
  final semantics = tester.ensureSemantics();
  addTearDown(semantics.dispose);
  var tapped = false;
  await tester.pumpWidget(_testApp(
    ReplyNotificationReminder(
      items: [_notification(11, '我的水帖')],
      totalCount: 1,
      onPressed: () => tapped = true,
    ),
  ));

  expect(find.text('互动回复'), findsOneWidget);
  expect(find.text('1 条新回复'), findsOneWidget);
  expect(find.text('回复者B'), findsOneWidget);
  expect(find.text('我的水帖'), findsOneWidget);
  expect(find.bySemanticsLabel('互动回复，1 条未读，查看'), findsOneWidget);
  await tester.tap(find.byKey(const ValueKey('home-reply-notification-reminder')));
  expect(tapped, isTrue);
});

testWidgets('多条列表选择只回调被点条目', (tester) async {
  final semantics = tester.ensureSemantics();
  addTearDown(semantics.dispose);
  UnreadReplyNotification? selected;
  await tester.pumpWidget(_testApp(
    Builder(builder: (context) => ReplyNotificationReminder(
      items: [_notification(11, '我的水帖'), _notification(12, '第二篇帖子')],
      totalCount: 2,
      onPressed: () => showReplyNotificationList(
        context,
        items: [_notification(11, '我的水帖'), _notification(12, '第二篇帖子')],
        onSelected: (value) => selected = value,
      ),
    )),
  ));
  await tester.tap(find.byKey(const ValueKey('home-reply-notification-reminder')));
  await tester.pumpAndSettle();
  expect(find.text('未读回复 (2)'), findsOneWidget);
  await tester.tap(find.text('第二篇帖子'));
  expect(selected?.id, 12);
});
```

同时用 `tester.getSize` 断言提醒整体高度至少 44 logical px；用 `GoldenTextProfile.large.scaler` 和 280px 宽度 pump，要求 `tester.takeException()` 为 null。

- [ ] **Step 2: 运行组件测试确认实现不存在。**

运行：`cd client; flutter test test/widgets/reply_notification_reminder_test.dart`

预期：FAIL，提示组件未定义。

- [ ] **Step 3: 实现提醒组件。**

组件使用 `AppColors.brandPrimary`、`AppSpacing`、`AppRadius.md`、`Theme.of(context).colorScheme` 和现有 `CachedAvatar`；不创建新的颜色、圆角或动画 token。摘要的交互 surface 使用 `Material + InkWell`，`ConstrainedBox(minHeight: 64)` 保证命中区；多条列表使用 `showModalBottomSheet(useSafeArea: true)`、`AppRadius.sheet`，每一行至少 64px。

组件公开接口固定为：

```dart
class ReplyNotificationReminder extends StatelessWidget {
  final List<UnreadReplyNotification> items;
  final int totalCount;
  final VoidCallback onPressed;

  const ReplyNotificationReminder({
    super.key,
    required this.items,
    required this.totalCount,
    required this.onPressed,
  });
}
```

在该类的 `build` 中直接展开下方 Semantics + Material + InkWell 结构；不得把该组件改成 Provider 或全局状态。

关键结构必须保持如下语义和截断规则。`ReplyNotificationReminder.build` 先取 `final latest = items.first;`，然后使用以下完整的摘要结构：

```dart
final latest = items.first;
Semantics(
  button: true,
  label: '互动回复，$totalCount 条未读，查看',
  child: Material(
    color: Theme.of(context).colorScheme.surface,
    borderRadius: BorderRadius.circular(AppRadius.md),
    child: InkWell(
      key: const ValueKey('home-reply-notification-reminder'),
      borderRadius: BorderRadius.circular(AppRadius.md),
      onTap: onPressed,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 64),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.md,
          ),
          child: Row(
            children: [
              const Icon(Icons.mark_chat_unread_outlined),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '互动回复',
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                        ),
                        Text(
                          '$totalCount 条新回复',
                          style: Theme.of(context).textTheme.labelMedium,
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      '${latest.fromUser?.nickname ?? '匿名'}：${latest.content}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    Text(
                      '《${latest.postTitle.isEmpty ? '帖子' : latest.postTitle}》',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    ),
  ),
)
```

摘要显示发送者、回复内容和 `《postTitle》`；发送者和标题分别用 `maxLines: 1`，回复内容用 `maxLines: 2`、`TextOverflow.ellipsis`，数量和右箭头不进入可压缩文本区域。列表项还显示头像、相对时间和同样的标题截断。相对时间复用帖子回复已有的“刚刚/分钟前/小时前/天前/月日”规则。

多条列表的入口函数也必须保持可测试的单条回调合同：

```dart
Future<void> showReplyNotificationList(
  BuildContext context, {
  required List<UnreadReplyNotification> items,
  required ValueChanged<UnreadReplyNotification> onSelected,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) => Material(
      color: Theme.of(sheetContext).colorScheme.surface,
      borderRadius: const BorderRadius.vertical(
        top: Radius.circular(AppRadius.sheet),
      ),
      child: SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.7,
          ),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.sm,
                ),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '未读回复 (${items.length})',
                    style: Theme.of(sheetContext).textTheme.titleMedium,
                  ),
                ),
              ),
              Expanded(
                child: ListView.separated(
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, index) {
                    final item = items[index];
                    return ListTile(
                      key: ValueKey('reply-notification-${item.id}'),
                      minVerticalPadding: AppSpacing.sm,
                      leading: CachedAvatar(
                        radius: 20,
                        imageUrl: item.fromUser?.avatar.isNotEmpty == true
                            ? ApiConstants.fullUrl(item.fromUser!.avatar)
                            : null,
                        fallbackText: item.fromUser?.nickname,
                      ),
                      title: Text(
                        item.fromUser?.nickname ?? '匿名',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${item.content} · 《${item.postTitle.isEmpty ? '帖子' : item.postTitle}》\n${_formatReplyNotificationTime(item.createdAt)}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () {
                        Navigator.of(sheetContext).pop();
                        onSelected(item);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

String _formatReplyNotificationTime(DateTime value) {
  final difference = DateTime.now().difference(value.toLocal());
  if (difference.inMinutes < 1) return '刚刚';
  if (difference.inHours < 1) return '${difference.inMinutes}分钟前';
  if (difference.inDays < 1) return '${difference.inHours}小时前';
  if (difference.inDays < 7) return '${difference.inDays}天前';
  final local = value.toLocal();
  return '${local.month}/${local.day}';
}
```

- [ ] **Step 4: 接入 `ShuitieScreen` 状态机。**

增加字段：

```dart
List<UnreadReplyNotification> _unreadReplyNotifications = [];
int _unreadReplyCount = 0;
final Set<int> _openingUnreadReplyIds = {};
```

使用 `ReplyNotificationService(auth.dio)` 实现 `_loadUnreadReplyNotifications()`：未登录时清空并不发请求；登录时记录 `sessionGeneration`，响应回来后若账号代次改变则丢弃；错误只 `debugPrint` 并保持空模块。调用点为首次 post-frame、`didChangeAppLifecycleState(resumed)`、`_refresh()`；登录切换回调清除旧账号数据并重新请求。加载中不渲染 skeleton，帖子流仍可使用。

在 `_buildFeedModeList` 的搜索 `SliverPersistentHeader` 后、`_freshnessBannerVisible` 前插入：

```dart
if (mode == 'new' && _unreadReplyNotifications.isNotEmpty)
  SliverToBoxAdapter(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md, AppSpacing.sm, AppSpacing.md, AppSpacing.xs,
      ),
      child: ReplyNotificationReminder(
        items: _unreadReplyNotifications,
        totalCount: _unreadReplyCount,
        onPressed: _handleUnreadReplyReminderPressed,
      ),
    ),
  ),
```

实现跳转合同：先 `GET /posts/{postId}`，成功解析 `Post` 后再调用 `markRead(notification.id)`；已读失败时不从本地列表移除，但仍允许用户进入详情，返回首页会再次刷新。已读成功才移除该条。使用现有路由：

```dart
final postResponse = await auth.dio.get('/posts/${item.postId}');
final post = Post.fromJson(postResponse.data as Map<String, dynamic>);
try {
  await ReplyNotificationService(auth.dio).markRead(item.id);
  _removeUnreadReply(item.id);
} catch (error) {
  debugPrint('消费回复通知失败: $error');
}
if (!mounted) return;
await Navigator.of(context).push(
  buildPostDetailRoute(post, targetReplyId: item.relatedId),
);
if (mounted) unawaited(_loadUnreadReplyNotifications());
```

单条时直接调用上述流程；多条时调用 `showReplyNotificationList`，回调选中的 item。通过 `_openingUnreadReplyIds` 防止重复点击造成重复已读请求。原帖 404 时显示 `AppFeedback.showSnackBar(context, '帖子已删除，已清除提醒', isError: true)`，只有 `markRead` 成功才移除本地条目；网络错误显示“打开帖子失败，请稍后重试”，保留未读。

- [ ] **Step 5: 扩展首页 feed 测试夹具和行为测试。**

在 `_FeedAuthProvider` 增加可配置 `loggedIn`，Dio interceptor 对 `/notifications/replies/unread` 返回固定 `count/items`，对 `/posts/100` 返回最小可解析帖子，对 `/notifications/read-selected` 记录 `ids`。新增测试覆盖：

测试夹具新增以下字段和 JSON helper，`_pumpFeed` 将 `unreadItems` 作为参数传入并把 `markedIds` 放入返回对象：

```dart
final List<int> markedIds = [];

class _FeedTestPage {
  const _FeedTestPage({
    required this.auth,
    required this.postProvider,
    required this.messageProvider,
    required this.themeProvider,
    required this.sectionProvider,
    required this.markedIds,
  });

  final _FeedAuthProvider auth;
  final PostProvider postProvider;
  final MessageProvider messageProvider;
  final ThemeProvider themeProvider;
  final WaterSectionProvider sectionProvider;
  final List<int> markedIds;
}

Map<String, dynamic> _unreadReplyJson({
  required int id,
  required int postId,
}) {
  return {
    'id': id,
    'post_id': postId,
    'related_id': id + 500,
    'content': '首页测试回复',
    'post_title': '首页测试帖子',
    'created_at': '2026-08-18T10:00:00Z',
    'from_user': {'id': 2, 'nickname': '回复者', 'avatar': ''},
  };
}
```

拦截 `/notifications/read-selected` 时将 `(options.data['ids'] as List).cast<int>()` 追加到 `markedIds`；未读接口响应固定为 `{'count': unreadItems.length, 'items': unreadItems}`。已读失败 fixture 必须 `handler.reject(DioException(requestOptions: options))`，原帖 404 fixture 必须带 `response: Response(statusCode: 404, requestOptions: options)`。

```dart
testWidgets('只有最新信息流显示首页互动回复模块', (tester) async {
  final page = await _pumpFeed(
    tester,
    loggedIn: true,
    unreadItems: [_unreadReplyJson(id: 11, postId: 100)],
  );
  await _pumpFrames(tester);
  await tester.tap(find.text('最新'));
  await tester.pump(const Duration(milliseconds: 160));
  expect(find.byKey(const ValueKey('home-reply-notification-reminder')), findsOneWidget);
  await tester.tap(find.byKey(const ValueKey('home-reply-notification-reminder')));
  await tester.pumpAndSettle();
  expect(page.markedIds, [11]);
  await _disposeFeed(tester, page);
});
```

另测无未读时 `find.byKey(const ValueKey('home-reply-notification-reminder'))` 为 `findsNothing`，通知请求 500 时同样隐藏且帖子错误/空态仍正常；多条时先断言列表出现，再点第二条并断言 payload 只有第二条 ID；原帖 404 时断言提醒仍保留，避免“失败却静默清除”。

- [ ] **Step 6: 运行客户端定向测试并提交首页功能。**

运行：`cd client; dart format lib/widgets/reply_notification_reminder.dart lib/screens/shuitie_screen.dart test/widgets/reply_notification_reminder_test.dart test/shuitie_feed_state_test.dart; flutter test test/widgets/reply_notification_reminder_test.dart test/shuitie_feed_state_test.dart`

预期：PASS；最新模式显示提醒，综合/精华/关注不显示，未读展示本身不触发已读请求，单条/多条消费均只提交选中 ID。

```bash
git add client/lib/widgets/reply_notification_reminder.dart client/lib/screens/shuitie_screen.dart client/test/widgets/reply_notification_reminder_test.dart client/test/shuitie_feed_state_test.dart
git commit -m "feat: show unread replies on latest feed"
```

### Task 5: 移除帖子详情页重复未读提示，保留目标定位

**Files:**
- Modify: `client/lib/screens/post_detail_screen.dart:184-220,263-300,2290-2320,2910-2930,346-390,5577-5795`
- Modify: `client/test/screens/post_detail_target_reply_test.dart`

- [ ] **Step 1: 写详情页回归测试。**

给 `FakeDio` 增加 `static final requestPaths = <String>[]`，在 `get` 开始处记录 path；每个测试 `setUp` 清空。新增断言：详情页加载完成后 `requestPaths` 不包含 `/notifications/unread`，且 `find.textContaining('未读回复')` 为 `findsNothing`；已有“目标不在列表时通过 context 定位”测试继续通过。

```dart
testWidgets('详情页不再查询或渲染未读回复提示', (tester) async {
  FakeDio.requestPaths.clear();
  final post = Post.fromJson({
    'id': 108,
    'title': '详情页回归帖',
    'content': '正文',
    'board_id': 2,
    'author_id': 1,
    'created_at': '2026-08-18T00:00:00.000Z',
  });
  await tester.pumpWidget(_postDetailTestApp(post));
  await tester.pumpAndSettle();
  expect(FakeDio.requestPaths.any((path) => path.contains('/notifications/unread')), isFalse);
  expect(find.textContaining('未读回复'), findsNothing);
});
```

- [ ] **Step 2: 运行测试确认当前实现会发旧请求并渲染旧提示。**

运行：`cd client; flutter test test/screens/post_detail_target_reply_test.dart -n "详情页不再查询或渲染未读回复提示"`

预期：FAIL，当前 `_loadPost` 会调用 `/posts/:id/notifications/unread`，详情结构中仍存在未读提示分支。

- [ ] **Step 3: 删除详情页未读状态、请求和 UI。**

删除 `_unreadReplyNotifications`、`_loadingUnreadReplies` 字段及其 import；从 `_loadPost` 删除 `_loadUnreadReplyNotifications()`；从集市详情和水帖评论区删除两个 `_buildUnreadReplyBanner` 条件；删除 `_loadUnreadReplyNotifications`、`_markNotificationsRead`、`_jumpToUnreadReply`、`_buildUnreadReplyBanner`、`_showUnreadReplySheet` 整段方法。不得删除 `_activeTargetReplyId`、`_prepareTargetReplyAndScroll`、`_scheduleScrollToTarget`。

为目标回复不存在的 404 增加明确反馈，网络失败仍保持详情页可浏览：

```dart
    } on DioException catch (error) {
      if (error.response?.statusCode == 404 && mounted) {
        AppFeedback.showSnackBar(context, '该回复可能已删除', isError: true);
      }
      return;
    } catch (_) {
      return;
    }
```

这段只放在 `_prepareTargetReplyAndScroll` 的 context 请求 catch 中；不会在详情页引入未读通知查询或已读操作。

- [ ] **Step 4: 运行详情页测试并检查旧路径引用为零。**

运行：`cd client; dart format lib/screens/post_detail_screen.dart test/screens/post_detail_target_reply_test.dart; flutter test test/screens/post_detail_target_reply_test.dart; rg -n "notifications/unread|_buildUnreadReplyBanner|_loadUnreadReplyNotifications|_markNotificationsRead" client/lib/screens/post_detail_screen.dart`

预期：定向测试 PASS，`rg` 无输出；`targetReplyId` 仍能定位已加载回复和 context 线程。

- [ ] **Step 5: 提交详情页清理。**

```bash
git add client/lib/screens/post_detail_screen.dart client/test/screens/post_detail_target_reply_test.dart
git commit -m "refactor: remove detail unread reply prompt"
```

### Task 6: 完成视觉 Goldens 和状态矩阵验收

**Files:**
- Create: `client/test/goldens/home_reply_notification_golden_test.dart`
- Create: `client/test/goldens/baselines/home/reply_notification_reminder_light_390x844.png`
- Create: `client/test/goldens/baselines/home/reply_notification_reminder_dark_360x800.png`
- Create: `client/test/goldens/baselines/home/reply_notification_reminder_large_360x800.png`

- [ ] **Step 1: 添加 focused-region Golden 测试。**

使用 `loadTestFonts()`、`setGoldenViewport()`、`GoldenTestApp()`，以真实中文内容构造 `ReplyNotificationReminder`，不要让网络头像参与像素基线（fixture 的 avatar 为空，走 fallback）。至少包含以下三组：

```dart
await expectLater(
  find.byType(MaterialApp),
  matchesGoldenFile('baselines/home/reply_notification_reminder_light_390x844.png'),
);

await expectLater(
  find.byType(MaterialApp),
  matchesGoldenFile('baselines/home/reply_notification_reminder_dark_360x800.png'),
);

await expectLater(
  find.byType(MaterialApp),
  matchesGoldenFile('baselines/home/reply_notification_reminder_large_360x800.png'),
);
```

每个测试的 state 在名称中明确 `single` 或 `multiple`，并保留 `dark`、`large-text` 证据；Goldens 只证明布局和换行，不替代组件交互测试。

- [ ] **Step 2: 运行 Windows 本地 QA，不更新 canonical 基线。**

运行：`cd client; flutter analyze --no-fatal-warnings --no-fatal-infos; flutter test test/widgets/reply_notification_reminder_test.dart test/services/reply_notification_service_test.dart test/shuitie_feed_state_test.dart test/screens/post_detail_target_reply_test.dart test/goldens/home_reply_notification_golden_test.dart`

预期：analyze 无新增错误；定向测试通过。Windows 上若仅出现 Skia/字体像素差异，不执行 `--update-goldens`。

- [ ] **Step 3: 在 Linux canonical 环境生成基线并复跑。**

仅在 Ubuntu + Flutter 3.41.8 stable 执行：`cd client; flutter test test/goldens/home_reply_notification_golden_test.dart --update-goldens`，随后执行不带 `--update-goldens` 的同一命令确认 PASS。将图片加入提交，不手工编辑 PNG。

- [ ] **Step 4: 记录 Design QA。**

按 `docs/design/DESIGN_QA.md` 记录：

- P0：0，首页点击提醒可进入原帖并定位目标回复。
- P1：0，单条/多条和已读失败均可恢复；详情页未读提示不再重复出现。
- P2：检查浅色、深色、1.3 倍文字、280px 窄屏的换行、标题/回复截断、surface 层级和 44px 触控区域；若有差异逐项记录，不以更新 Golden 掩盖。
- P3：只记录不影响功能的文字间距或视觉 polish，不阻塞本次功能验收。

- [ ] **Step 5: 提交视觉测试基线。**

```bash
git add client/test/goldens/home_reply_notification_golden_test.dart client/test/goldens/baselines/home
git commit -m "test: add reply reminder visual coverage"
```

### Task 7: 集成回归和交付检查

**Files:**
- No new files; inspect all files changed by Tasks 1-6.

- [ ] **Step 1: 静态检查需求覆盖和旧行为移除。**

运行：

```bash
rg -n "notifications/replies/unread" server client
rg -n "posts/.+notifications/unread|_buildUnreadReplyBanner|_showUnreadReplySheet|全部标记已读" client/lib/screens/post_detail_screen.dart
```

预期：第一条只命中服务端路由/handler、客户端 service/test；第二条无输出。

- [ ] **Step 2: 运行服务端和客户端完整验证。**

运行：`cd server; go test ./...`；`cd ..\client; flutter analyze --no-fatal-warnings --no-fatal-infos`；`flutter test --reporter compact`。

预期：三条命令均 PASS；若 Flutter 全量测试因环境插件缺失失败，必须保留失败测试名和错误，不将定向通过描述为全量通过。

- [ ] **Step 3: 手工验收真实页面流程。**

在已登录账号准备一条自己发帖、另一用户回复的数据，验证：

1. 进入首页“水帖 / 最新”，搜索框下看到发送者、回复摘要、原帖标题和未读总数；停留不改变已读。
2. 一条未读点击直接进入原帖并定位；返回首页后该条消失，剩余未读继续显示。
3. 多条未读点击模块打开列表，选择一条只消费一条。
4. 原帖被删除时看到“帖子已删除，已清除提醒”；网络/已读失败时条目仍保留。
5. 直接进入帖子详情时不再显示“有新回复”横幅、BottomSheet 或“全部标记已读”。

- [ ] **Step 4: 最终提交前检查。**

确认未修改系统推送、私信、“我的-通知”页、回复创建逻辑和 `docs/design/` 冻结决策；确认所有新增代码注释为中文，未引入新全局色、radius、动效依赖或 `PostProvider` 职责膨胀。

## 计划自检

- 需求覆盖：首页可见提醒、单条直达、多条列表、按条消费、原帖删除消费、详情页移除重复提示、targetReplyId 定位、失败保留未读、认证隔离、批量查询、深浅色和大字号均有对应任务。
- 占位符扫描：本计划不使用 `TODO`、`TBD` 或“稍后补充”等待定步骤；每个代码步骤给出了目标文件、接口名、测试命令和预期结果。
- 类型一致性：服务端返回 `count/items`；客户端使用 `UnreadReplyNotificationPage.count/items`；通知项字段统一为 `id/post_id/related_id/content/post_title/created_at/from_user`；已读统一调用 `markRead(int)`，详情路由统一传 `targetReplyId`。
- 范围检查：不删除服务端旧兼容接口，不改变现有通知页和推送行为；仅删除详情页重复消费路径。
