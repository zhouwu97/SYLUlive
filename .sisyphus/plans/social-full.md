# Social Follow 全链路计划

## 目标

修复 3 个后端 bug + 裁剪获赞统计 + 前端从占位符到真实数据闭环。

---

## Step 1: 后端 Hotfix (3 bugs)

### 1a) GetUserInfo 返回格式破坏

**models/user.go** — `IsCheckedInToday` 下面加：
```go
IsFollowing bool `gorm:"-" json:"is_following"`
```

**handlers/user.go** `GetUserInfo` — 把：
```go
c.JSON(http.StatusOK, gin.H{"user": user, "is_following": isFollowing})
```
改为：
```go
user.IsFollowing = isFollowing
c.JSON(http.StatusOK, user)
```

### 1b) Like handler 并发冲突

**handlers/like.go**：
- import 加 `"gorm.io/gorm/clause"`
- LikePost/LikeReply/UnlikePost/UnlikeReply 四个方法中，**删除**事务外的 `First(&existing)` 查重
- 事务内 Create 改为：
```go
result := tx.Clauses(clause.OnConflict{DoNothing: true}).Create(&like)
if result.RowsAffected == 0 { return nil }
```

### 1c) Followers/Following 分页元数据

**handlers/user.go** `GetFollowers` 和 `GetFollowing` 返回改为：
```go
var total int64
h.db.Model(&models.UserFollow{}).Where("following_id = ?", targetID).Count(&total)
c.JSON(http.StatusOK, gin.H{"users": users, "total": total, "page": page, "limit": limit})
```
GetFollowing 的 Count 条件换为 `"follower_id = ?"`。

---

## Step 2: 后端 — 裁剪获赞统计

**handlers/like.go** `LikeReply` 和 `UnlikeReply`：
- 删除事务内更新作者 `total_likes_received` 的行（`tx.Model(&models.User{}).Where("id = ?", ...)`）
- 保留帖子/回复自身的 like_count 更新

---

## Step 3: 数据库脏数据校准

```sql
UPDATE users SET total_likes_received = (
  SELECT COUNT(*) FROM likes
  WHERE target_type = 'post'
  AND target_id IN (SELECT id FROM posts WHERE author_id = users.id)
);
```

---

## Step 4: 前端 Model + API 层

### 4a) models/user.dart

新增字段和序列化：
```dart
final int followersCount;
final int followingCount;
final int totalLikesReceived;
final bool isFollowing;
```

### 4b) 新建 providers/social_provider.dart

```dart
class SocialProvider extends ChangeNotifier {
  final Dio _dio;
  SocialProvider(this._dio);

  Future<bool> follow(int userId) async {
    await _dio.post('/user/$userId/follow');
    return true;
  }
  Future<bool> unfollow(int userId) async { ... DELETE }
  Future<Map> getFollowers(int userId, {int page=1}) async {
    final r = await _dio.get('/user/$userId/followers', queryParameters: {'page': page, 'limit': 20});
    return r.data; // {users, total, page, limit}
  }
  Future<Map> getFollowing(int userId, {int page=1}) async { ... }
  Future<User> getUserProfile(int userId) async {
    final r = await _dio.get('/user/$userId');
    return User.fromJson(r.data);
  }
  Future<List<Post>> getUserPosts(int userId, {int page=1}) async { ... }
}
```

**main.dart** 注册：`ChangeNotifierProvider(create: (_) => SocialProvider(dio))`

---

## Step 5: 前端页面实现

### 5a) user_home_screen.dart 改造

- 构造函数加 `final int? userId;`（null = 看自己）
- `initState` 调 `context.read<SocialProvider>().getUserProfile(userId ?? currentUser.id)`
- 统计区：`${user.totalLikesReceived}` / `${user.followingCount}` / `${user.followersCount}`
- 关注/粉丝数字：**自己**可点击跳转 SocialListScreen，**别人主页不可点击**（GestureDetector 条件判断）
- Tab "帖子 N"：N 来自 `getUserPosts` 返回的 total
- 帖子列表 Tab 内容：替换 `MockPostListTab` 为真实帖子列表（复用 PostCard）
- 编辑资料按钮：`userId == null` 时显示；别人显示「关注/已关注」按钮

### 5b) 帖子作者头像跳转

**widgets/post_card.dart** — 作者头像/昵称加 `onTap`：
```dart
Navigator.push(context, MaterialPageRoute(
  builder: (_) => UserHomeScreen(userId: post.authorId),
));
```

**screens/post_detail_screen.dart** — 帖子详情作者卡片、回复中的作者头像同理加跳转。

### 5c) screens/social_list_screen.dart 新建

```
Scaffold
├── AppBar(title: "关注和粉丝")
├── TabBar(tabs: ["关注", "粉丝"])
└── TabBarView
    ├── 关注列表 ListView
    │   └── 每行: 头像 + 昵称 + 签名 + 取消关注按钮(仅自己)
    └── 粉丝列表 ListView
        └── 每行: 头像 + 昵称 + 签名 + 回关/已关注按钮(仅自己)
```

- 列表项头像点击 → `UserHomeScreen(userId: ...)`
- 上拉加载更多分页
- 取消关注后局部刷新列表

---

## 验证

- [ ] `go build ./... && go test ./...`
- [ ] `flutter analyze`
- [ ] 自己主页统计与数据库一致
- [ ] 别人主页正确显示 + 关注按钮可用
- [ ] 别人主页关注/粉丝数字不可点
- [ ] 帖子作者头像跳转正常
- [ ] 脏数据校准后 total_likes_received 正确
