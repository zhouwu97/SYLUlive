# Social Follow System — 后端实现计划

> 目标：实现关注/取关、粉丝/关注列表、获赞统计、个人主页帖子列表
> 方法：TDD（测试先写，红-绿-重构）
> 分支：`social-follow-system`

---

## 差距清单

| # | 文件 | 问题 | 等级 |
|---|------|------|------|
| 1 | `models/like.go` | 无 UNIQUE(user_id, target_type, target_id)，并发可重复点赞 | 🔴 数据正确性 |
| 2 | `models/user.go` | 缺 followers_count / following_count / total_likes_received | 🔴 功能缺失 |
| 3 | `models/` | 缺 user_follow.go（关注关系表） | 🔴 功能缺失 |
| 4 | `handlers/like.go` | LikePost/UnlikePost/LikeReply/UnlikeReply 只更新帖子/回复 like_count，未同步更新作者 total_likes_received | 🔴 计数不准 |
| 5 | `handlers/user.go` | 缺 Follow / Unfollow / GetFollowers / GetFollowing / GetUserPosts / IsFollowing；GetUserInfo 缺 is_following 字段 | 🔴 功能缺失 |
| 6 | `cmd/main.go` | 缺 UserFollow AutoMigrate 注册 + 6 条新路由 | 🔴 不可用 |

---

## 验收标准

- [ ] 关注/取关接口幂等（重复操作不报错，状态正确）
- [ ] 并发点赞不产生重复记录（UNIQUE 约束兜底）
- [ ] 关注者、被关注者计数与 user_follows 表记录数一致
- [ ] 点赞/取消点赞同步更新作者 total_likes_received
- [ ] 粉丝列表和关注列表正确分页
- [ ] 自己看自己主页 is_following = false
- [ ] 他人主页 is_following 通过 EXISTS 查询正确返回
- [ ] 帖子列表只返回 status='normal' 的帖子
- [ ] 所有新接口通过自动化测试
- [ ] 现有接口不受影响（回归测试通过）
- [ ] `flutter analyze` 通过
- [ ] `go build ./...` 通过

---

## 实施步骤（TDD 红-绿-重构）

### Step 1: 修复 Like 模型唯一索引

**文件**: `server/internal/models/like.go`

**改动**: UserID、TargetType、TargetID 三字段共用 `uniqueIndex:idx_like_unique`

**测试**: `models/like_test.go` — 验证重复插入被拒绝

---

### Step 2: 新建 UserFollow 模型

**文件**: `server/internal/models/user_follow.go`（新建）

**结构**:
```go
type UserFollow struct {
    ID          uint      `gorm:"primaryKey"`
    FollowerID  uint      `gorm:"not null;uniqueIndex:idx_follow_unique"`
    FollowingID uint      `gorm:"not null;uniqueIndex:idx_follow_unique;index"`
    CreatedAt   time.Time
}
```

**测试**: `models/user_follow_test.go` — 验证 UNIQUE 约束和索引

---

### Step 3: 扩展 User 模型计数字段

**文件**: `server/internal/models/user.go`

**新增字段**:
```go
FollowersCount     int `gorm:"default:0" json:"followers_count"`
FollowingCount     int `gorm:"default:0" json:"following_count"`
TotalLikesReceived int `gorm:"default:0" json:"total_likes_received"`
```

**无需单独测试**（GORM AutoMigrate 保证字段存在）

---

### Step 4: 改造点赞 Handler（事务内同步作者计数）

**文件**: `server/internal/handlers/like.go`

**改动**: LikePost / UnlikePost / LikeReply / UnlikeReply 四个方法

**逻辑**（以 LikePost 为例）:
```go
db.Transaction(func(tx *gorm.DB) error {
    // 1. 插入点赞（幂等：UNIQUE 冲突则忽略）
    tx.Create(&like)
    // 2. 更新帖子 like_count
    tx.Model(&Post{}).Where("id = ?", postID).Update("like_count", gorm.Expr("like_count + 1"))
    // 3. 查帖子作者 → 更新作者 total_likes_received
    var post Post
    tx.First(&post, postID)
    tx.Model(&User{}).Where("id = ?", post.AuthorID).Update("total_likes_received", gorm.Expr("total_likes_received + 1"))
})
```

**测试**: `handlers/like_handler_test.go` — 验证事务内计数原子性、幂等性

---

### Step 5: 新增社交接口 Handler

**文件**: `server/internal/handlers/user.go`

**新增方法**:

| 方法 | 路由 | 说明 |
|------|------|------|
| `Follow` | `POST /api/user/:id/follow` | 已关注→幂等200；未关注→INSERT + 双向计数+1 |
| `Unfollow` | `DELETE /api/user/:id/follow` | 未关注→幂等200；已关注→DELETE + 双向计数-1 |
| `GetFollowers` | `GET /api/user/:id/followers?page&limit` | JOIN users，按 created_at 倒序分页 |
| `GetFollowing` | `GET /api/user/:id/following?page&limit` | JOIN users，按 created_at 倒序分页 |
| `GetUserPosts` | `GET /api/user/:id/posts?page&limit` | WHERE author_id=:id AND status='normal' |
| `IsFollowing` | `GET /api/user/:id/is-following` | SELECT EXISTS(...) |

**GetUserInfo 改造**: 响应体增加 `is_following: bool`（通过 EXISTS 子查询）

**测试**: `handlers/user_handler_test.go` — 每个方法单独测试

---

### Step 6: 注册路由和 AutoMigrate

**文件**: `server/cmd/main.go`

**AutoMigrate**: 列表增加 `&models.UserFollow{}`

**路由**（在 `/api/user` 组内）:
```go
user.POST("/:id/follow", userHandler.Follow)
user.DELETE("/:id/follow", userHandler.Unfollow)
user.GET("/:id/followers", userHandler.GetFollowers)
user.GET("/:id/following", userHandler.GetFollowing)
user.GET("/:id/posts", userHandler.GetUserPosts)
user.GET("/:id/is-following", userHandler.IsFollowing)
```

**注意**: `GetUserPosts` 和 `IsFollowing` 不需要强制登录？需确认——当前设计：统一用 `AuthMiddleware`。

---

## 自审分类

| 等级 | 项 | 理由 |
|------|-----|------|
| 🔴 Critical | like.go UNIQUE 索引 | 数据正确性，并发下现有代码可产生重复点赞 |
| 🔴 Critical | like.go 作者计数 | 不修则 total_likes_received 永远为 0 |
| 🔴 Critical | user_follow.go + routes | 功能完全缺失 |
| 🟡 Minor | user.go 计数字段 | GORM AutoMigrate 自动处理 |
| 🟡 Minor | cmd/main.go 注册 | 纯粹的路由声明 |

---

## 决定事项（已确认）

- ✅ TDD（用户确认）
- ✅ 显式 POST/DELETE follow（非 toggle）
- ✅ 不引入 Redis（当前规模不需要）
- ✅ is_following 用 EXISTS 子查询
- ✅ following_id 单独索引（加速粉丝查询）

---

> 下一步：调用 Momus 审查此计划，或直接 `/start-work` 开始实现。
