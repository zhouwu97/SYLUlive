# 沈理校园 (SYLUlive) Backend API Documentation

本文件旨在提供沈理校园后端的 HTTP API 接口概览。所有的接口均基于 RESTful 风格设计，通过 JSON 格式进行数据交互。

## 基础信息

- **基础路由 (Base URL)**: `/api`
- **内容类型 (Content-Type)**: `application/json` (除文件上传外)
- **鉴权方式 (Authentication)**: 大部分接口依赖 JWT 进行鉴权，通过 `Authorization: Bearer <token>` 传递。

---

## 目录

1. [认证与注册 (Auth)](#1-认证与注册-auth)
2. [用户与个人中心 (User)](#2-用户与个人中心-user)
3. [教务系统 (Edu)](#3-教务系统-edu)
4. [帖子与社区 (Posts & Replies)](#4-帖子与社区-posts--replies)
4.1. [Feed 推荐用户控制 (Feed)](#41-feed-推荐用户控制-feed)
4.2. [Feed 行为事件采集 (Feed Events)](#42-feed-行为事件采集-feed-events)
5. [榜单与评价 (Ratings)](#5-榜单与评价-ratings)
6. [消息与通知 (Messages)](#6-消息与通知-messages)
7. [管理员与超级管理员 (Admin)](#7-管理员与超级管理员-admin)
8. [公共服务 (Public & AI)](#8-公共服务-public--ai)

---

## 1. 认证与注册 (Auth)

公共接口，无需 JWT 鉴权。

| Method | Endpoint | Description |
|---|---|---|
| `POST` | `/api/send_code` | 发送邮箱验证码 |
| `POST` | `/api/verify_code` | 验证邮箱验证码 |
| `POST` | `/api/register` | 用户注册 (邮箱) |
| `POST` | `/api/login` | 用户登录 (邮箱+密码) |
| `POST` | `/api/login_edu` | 教务系统登录绑定 |
| `POST` | `/api/register_with_edu` | 仅教务绑定的一键注册 |
| `POST` | `/api/forgot_password` | 忘记密码找回 |
| `POST` | `/api/change_password` | 修改密码 (需 JWT) |

## 2. 用户与个人中心 (User)

大部分需 JWT 鉴权。

| Method | Endpoint | Description |
|---|---|---|
| `GET` | `/api/user/profile` | 获取当前用户资料 |
| `PUT` | `/api/user/profile` | 更新个人资料 (昵称、性别等) |
| `PUT` | `/api/user/avatar` | 更新头像 URL |
| `PUT` | `/api/user/background`| 更新个人主页背景 |
| `GET` | `/api/user/:id` | 获取指定用户信息 |
| `POST`| `/api/user/checkin` | 用户每日签到 |
| `POST`| `/api/user/checkin/makeup` | 使用补签卡补签本月过去的未签到日期 |
| `GET` | `/api/user/checkin/status` | 获取签到状态 |
| `GET` | `/api/user/checkin/calendar?month=YYYY-MM` | 获取指定月份的签到记录 |
| `POST`| `/api/user/:id/follow` | 关注指定用户 |
| `DELETE`| `/api/user/:id/follow`| 取消关注指定用户 |
| `GET` | `/api/user/:id/posts` | 获取指定用户发布的帖子 |

## 3. 教务系统 (Edu)

| Method | Endpoint | Description |
|---|---|---|
| `POST` | `/api/edu/bind` | 绑定强智教务系统 |
| `DELETE` | `/api/edu/bind` | 解绑教务系统 |
| `GET` | `/api/edu/status` | 获取当前教务绑定状态 |
| `POST` | `/api/edu/courses` | 抓取或获取教务课表 |
| `POST` | `/api/edu/grades` | 查询教务成绩 |
| `POST` | `/api/exam/extract` | 融智云考题库一键提取 |
| `POST` | `/api/erke/scores` | 青年之声（第二课堂）学分查询 |

### 已授权二课快照

以下接口均需 JWT。它们只接受手机已解析的结构化二课数据，用于校园 Agent 的后续分析；服务端拒绝密码、Cookie、会话、设备密钥和原始 HTML，客户端传入的哈希不会被信任。

| Method | Endpoint | Description |
|---|---|---|
| `PUT` | `/api/personal-snapshots/erke` | 按用户明确授权上传或替换二课结构化快照 |
| `GET` | `/api/personal-snapshots/erke` | 读取当前用户已上传的二课快照及来源、更新时间、过期状态 |
| `DELETE` | `/api/personal-snapshots/erke` | 删除已上传的二课快照，后续校园 Agent 不再读取 |

`PUT /api/personal-snapshots/erke` 请求示例：

```json
{
  "schema_version": 2,
  "fetched_at": "2026-07-25T09:20:00+08:00",
  "graduation": {"earned_total": 42.5, "required_total": 60},
  "yearly": {"year": "2025-2026", "earned_total": 12},
  "recent_activities": [{"name": "志愿服务", "credits": 1.5}]
}
```

错误码：`invalid_erke_snapshot` 表示字段不符合结构、超过大小限制或含敏感字段；`personal_snapshot_not_found` 表示尚未上传或已经删除；`personal_snapshot_unavailable` 表示服务暂时不可用。

## 4. 帖子与社区 (Posts & Replies)

**帖子 (Posts)**
| Method | Endpoint | Description |
|---|---|---|
| `GET` | `/api/posts` | 获取帖子列表 (支持分页、分类、搜索) |
| `POST` | `/api/posts` | 发布新帖子 |
| `GET` | `/api/posts/:id` | 获取单篇帖子详情 |
| `DELETE` | `/api/posts/:id` | 删除帖子 |
| `POST` | `/api/posts/:id/like` | 点赞帖子 |

**回复与评论 (Replies)**
| Method | Endpoint | Description |
|---|---|---|
| `GET` | `/api/posts/:id/replies`| 获取某帖子的回复列表 |
| `POST` | `/api/posts/:id/replies`| 发表回复或楼中楼 |
| `DELETE` | `/api/replies/:id` | 删除回复 |
| `POST` | `/api/replies/:id/like`| 点赞回复 |

## 4.1 Feed 推荐用户控制 (Feed) — FEED-1

需要登录（AuthMiddleware）。负反馈过滤自动作用于首页信息流：
- 不看TA（隐藏作者）：综合 / 最新 / 精华 / 关注 全部生效；
- 不感兴趣：仅「综合」生效（最新/关注是用户主动查看路径，不偷偷过滤）。

| Method | Endpoint | Description |
|---|---|---|
| `PUT` | `/api/feed/posts/:post_id/not-interested` | 标记不感兴趣。`source` query 可选：`all`/`time`/`featured`/`following`，表示点击时所在 Tab，仅用于分析，默认 `all`。有效期 90 天，重复标记会续期 |
| `DELETE` | `/api/feed/posts/:post_id/not-interested` | 撤销不感兴趣（幂等） |
| `PUT` | `/api/feed/authors/:author_id/hidden` | 不看TA：隐藏该作者（幂等，不取消关注） |
| `DELETE` | `/api/feed/authors/:author_id/hidden` | 恢复显示该作者（幂等） |
| `GET` | `/api/feed/hidden-authors` | 获取已隐藏作者列表（含昵称/头像，按隐藏时间倒序） |

语义说明：
- `HideFromFeed != BlockUser`：隐藏只影响 Feed 列表，不影响搜索、主页、直接帖子 URL、评论区与私信。
- 「不看TA」与关注关系（`UserFollow`）无关：隐藏不取消关注，恢复后作者自然重新出现在关注流。

FEED-H1 加固：
- `not_interested` 有效期 90 天（`expires_at`），重复标记刷新有效期；历史无 `expires_at` 记录视为仍有效。
- 不能隐藏自己、不能对自己的帖子标记不感兴趣（返回 `400`）。
- 综合推荐 Snapshot 绑定用户：`loadmore` 时归属不匹配返回 `409 feed_session_expired`；隐藏作者 / 不感兴趣 / 撤销 / 恢复后，旧综合快照立即失效。

## 4.2 Feed 行为事件采集 (Feed Events) — FEED-2

需要登录（AuthMiddleware）。用于推荐系统曝光 / 打开 / 停留数据采集。

| Method | Endpoint | Description |
|---|---|---|
| `POST` | `/api/feed/events/batch` | 批量上报 Feed 行为事件（幂等） |

请求体：

```json
{
  "feed_session_id": "事件专用 session，与快照 session_id 分离",
  "feed_kind": "all | time | featured | following",
  "algorithm_version": "home_all_v3_poll",
  "events": [
    { "type": "impression", "post_id": 1, "position": 3, "visible_ms": 800 },
    { "type": "open", "post_id": 1 },
    { "type": "dwell", "post_id": 1, "dwell_ms": 5000 }
  ]
}
```

幂等语义（单次请求内相同 `user + feed_session_id + feed_kind + post_id` 合并为一行）：

- `impression`：upsert，`visible_ms` 取最大；
- `open`：`opened_at` 取最早非空值，重复发送不增加数量；
- `dwell`：`dwell_ms` 取最大，禁止累加，防止重试把阅读时长翻倍。

限制：单次最多 500 条事件。`feed_session_id` 与现有快照 `session_id` 是两个概念，不要混用。

## 5. 榜单与评价 (Ratings)

提供教师避雷榜、专业榜、食堂榜的评价体系。

| Method | Endpoint | Description |
|---|---|---|
| `GET` | `/api/teachers` | 获取教师榜单列表 |
| `GET` | `/api/teachers/:id` | 获取教师详情及评价 |
| `POST` | `/api/teachers/:id/rate` | 评价教师 |
| `DELETE` | `/api/teachers/rating/:id` | 删除自己的教师评价 |
| `GET` | `/api/majors` | 获取专业评价列表 |
| `GET` | `/api/majors/:id` | 获取专业详情及评价 |
| `POST` | `/api/majors/:id/rate` | 评价专业 |
| `DELETE` | `/api/majors/rating/:id` | 删除自己的专业评价 |
| `GET` | `/api/canteens` | 获取食堂评分列表（Bayesian 排序；含 `dish_count`/`dish_photo_count`） |
| `GET` | `/api/canteens/:id?review_sort=best\|latest&review_filter=all\|with_image\|high\|low` | 公开获取食堂详情及评价；登录时附带个人评价/投票状态 |
| `POST` | `/api/canteens/:id/rate` | 评价食堂（需登录并绑定教务） |
| `PUT` | `/api/canteens/ratings/:ratingId/vote` | 给食堂评价点赞/点踩/取消投票，不能给自己的评价投票 |
| `PUT` | `/api/canteens/:id/image` | (管理员) 修改食堂封面图片 |
| `POST` | `/api/canteens` | (需登录) 提交新食堂，进入待审核；`verified=false` 不公开，管理员收到站内通知 |
| `GET` | `/api/canteens/pending` | (管理员) 待审核食堂列表（含 `creator_name` 提交人昵称） |
| `POST` | `/api/canteens/:id/approve` | (管理员) 通过审核，文件转 `public`，通知提交者 |
| `DELETE` | `/api/canteens/:id/pending` | (管理员) 驳回并删除待审提交，可带 `{"reason": "..."}` 通知提交者 |

### 食堂评价投票

`PUT /api/canteens/ratings/:ratingId/vote`

请求体：

```json
{
  "vote": "up"
}
```

`vote` 可选值：

| Value | Description |
|---|---|
| `up` | 点赞；已点赞时再次提交会取消 |
| `down` | 点踩；已点踩时再次提交会取消 |
| `none` | 取消当前投票 |

成功响应：

```json
{
  "message": "操作成功",
  "rating_id": 1,
  "helpful_count": 12,
  "unhelpful_count": 1,
  "my_vote": "up"
}
```

食堂详情返回的每条 `ratings` 会包含 `helpful_count`、`unhelpful_count`、`my_vote`。`my_vote` 为 `up`、`down` 或 `null`。

### 食堂菜品实拍 (Canteen Dish Photos)

菜品图库：每道菜最多 3 张审核通过的实拍；`dish.status = active AND approved 实拍 > 0` 才公开展示。菜名不单独审核，管理员审核图片时一并查看。

| Method | Endpoint | Description |
|---|---|---|
| `GET` | `/api/canteens/:id/dishes` | 公开菜品列表（approved-only），返回 `id/name/cover_image/photo_count/last_photo_at` |
| `GET` | `/api/canteens/:canteenId/dishes/:dishId` | 公开菜品详情 + approved 实拍列表 |
| `POST` | `/api/canteens/:canteenId/dish-photos` | (需登录+绑定教务) 投稿实拍，单图 |
| `GET` | `/api/canteens/dish-photos/pending` | (管理员) 待审核实拍列表 |
| `POST` | `/api/canteens/dish-photos/:photoId/approve` | (管理员) 通过实拍，文件转 public |
| `POST` | `/api/canteens/dish-photos/:photoId/reject` | (管理员) 驳回实拍，文件保持 private |
| `POST` | `/api/canteens/dish-photos/:photoId/archive` | (管理员) 下架实拍（业务隐藏，不 revoke 文件） |
| `PATCH` | `/api/canteens/dishes/:dishId` | (管理员) 重命名或隐藏菜品 |

**投稿**

`POST /api/canteens/:canteenId/dish-photos`，Body 二选一：

```json
{ "dish_id": 12, "file_id": 9527 }
```

或（未找到菜品时按名称创建/复用）：

```json
{ "dish_name": "锅包肉", "file_id": 9527 }
```

- 菜名归一化：trim、合并并删除内部空白、兼容全角空格、转小写（`"锅 包 肉"` → `"锅包肉"`），同食堂归一化菜名唯一。
- 一次投稿严格一张图片（服务端 `maxCount=1` 硬限制）。
- 投稿后 `DishPhoto.status = pending`，文件保持 `active/private`，公共接口不可见。

错误码：

| Status | code | 说明 |
|---|---|---|
| 403 | `edu_binding_required` | 未绑定教务 |
| 409 | `dish_gallery_full` | 该菜品已有 3 张审核实拍 |
| 409 | `pending_photo_exists` | 同一用户同一菜已有待审核实拍 |
| 409 | `duplicate_photo` | 图片文件已被其他投稿引用 |
| 409 | `already_reviewed` | 实拍已被审核处理 |

**驳回原因 code**：`unrelated`（与菜品不符）、`blurry`（图片过于模糊）、`duplicate`（重复图片）、`privacy`（包含明显个人隐私）、`advertisement`（广告/二维码）、`inappropriate`（不适宜内容）、`other`（其他）。

**文件生命周期**：`/upload` → `temporary/private` → 投稿 `ClaimPrivateFiles` → `active/private` → 管理员通过 `ClaimPublicImageFiles` → `active/public`；驳回保持 `private`；下架仅业务隐藏，不强制 revoke（文件可能被其他公开业务引用）。

## 6. 消息与通知 (Messages)

| Method | Endpoint | Description |
|---|---|---|
| `GET` | `/api/messages/conversations` | 获取私信会话列表 |
| `GET` | `/api/messages/conversations/:id`| 分页获取聊天记录，支持 `limit` 和 `before_id` |
| `POST`| `/api/messages/:user_id` | 发送私信，首次发送时自动创建会话 |
| `POST`| `/api/messages/conversations/:id/read` | 将会话中的接收消息标记为已读 |
| `GET` | `/api/messages/unread_count` | 获取私信未读总数 |
| `GET` | `/api/user/notifications/unread_count`| 获取未读系统通知和互动红点数 |
| `POST`| `/api/user/notifications/read` | 标记所有通知为已读 |

## 6.1 统一搜索 (Search)

| Method | Endpoint | Description |
|---|---|---|
| `GET` | `/api/search?type=posts&q=关键词&sort=relevance` | 按标题或正文搜索帖子，支持 relevance/latest/hot |
| `GET` | `/api/search?type=users&q=用户ID或昵称&sort=relevance` | 公开搜索仅支持精确用户 ID 或昵称，支持 relevance/newest |

## 7. 管理员与超级管理员 (Admin)

需要特殊角色权限 (Admin/SuperAdmin)。

**管理员管理 (Admin)**
| Method | Endpoint | Description |
|---|---|---|
| `GET` | `/api/admin/members` | 获取当前管理员列表，返回用户 ID 与学号/登录账号 |
| `POST` | `/api/admin/invite/:id`| 邀请指定用户成为管理员 |
| `POST` | `/api/teachers/admin/:id/vote-remove` | 投票罢免管理员 |
| `GET` | `/api/admin/feed/metrics?from=YYYY-MM-DD&to=YYYY-MM-DD&feed_kind=all` | Feed 每日指标（曝光/open/CTR/avg_dwell/互动密度/负反馈）；默认最近 7 个上海自然日 |
| `GET` | `/api/admin/feed/metrics/baseline?date=YYYY-MM-DD` | 单日补充基线：top-20 多样性 / 新帖公平性 / 冷启动 CTR |

**超级管理员 (Super Admin)**
| Method | Endpoint | Description |
|---|---|---|
| `GET` | `/api/super/users` | 全局用户风控管理列表，可按用户 ID、学号/登录账号或昵称搜索 |
| `PUT` | `/api/super/users/:id/role`| 直接修改用户角色层级 |
| `POST`| `/api/super/users/:id/reset_password`| 强制重置密码 |
| `GET` | `/api/super/stats` | 获取系统整体统计大盘数据 |

## 8. 公共服务 (Public & AI)

| Method | Endpoint | Description |
|---|---|---|
| `POST` | `/api/upload` | 上传单张图片/文件 |
| `GET` | `/api/announcements/active` | 获取活跃系统公告 |
| `POST` | `/api/feedback` | 提交产品功能建议或Bug |
| `POST` | `/api/v1/question/solve` | 触发大模型 AI 解答题目接口 |

> **注**: 以上仅为摘要级接口列表。请求载荷 (Body) 和返回体结构请参考对应处理器 (Handlers) 的 Go 源码定义。

## 试卷库

普通接口均需 JWT；普通用户还需完成教务认证，管理员可绕过教务认证。

- `GET /api/exam-papers`：已发布列表，支持 `keyword`、`academic_year`、`semester`、`exam_type`、`sort`、`page`、`page_size`。响应额外包含 `academic_years`：全部已发布试卷的去重学年列表，按倒序排列，不受本次筛选条件影响。
- `GET /api/exam-papers/:id`：已发布详情。
- `POST /api/exam-papers/upload-sessions`：创建 10 分钟有效的远端直传会话。JSON 字段为 `course_name`、`academic_year`、`semester`、`exam_type`、`privacy_confirmed=true`、`file_size`，成功返回 `session_id`、`upload_url`、`upload_token` 和 `expires_at`。文件服务器按 `expected_size + 1` 字节流式早停，实际 PDF 字节数必须与授权中的 `expected_size` 完全一致，大小不符时不会进入 PDF 深度校验或落盘。
- `POST /api/exam-papers/upload-sessions/:id/complete`：提交文件服务器返回的 `receipt`，验证会话归属和回执后创建试卷投稿；普通用户最多同时保留 5 份待审核投稿。重复完成同一会话会返回同一份试卷，不重复创建记录或任务。
- `POST /api/exam-papers`：仅供 `local` 存储模式下的旧客户端使用。启用 `remote` 后立即返回 HTTP `426` 和 `client_upgrade_required`，主服务器不会读取 multipart 文件体。
- `GET /api/exam-papers/my-submissions`：我的投稿列表，支持 `status=all|pending|published|unpublished`、`page`、`page_size`；响应中的 `status_counts` 返回本人全部投稿在 `all`、`pending`、`published`、`unpublished` 各状态下的数量。未传 `status` 时为兼容旧客户端，仅返回待审核和已发布投稿。
- `DELETE /api/exam-papers/my-submissions/:id`：删除本人投稿。`pending` 状态执行撤回；`published`、`unpublished` 状态执行永久删除，并按实际奖励状态撤销经验。成功响应为 `{"message":"投稿已撤回|投稿已永久删除","exp_revoked":true|false}`。
- `GET /api/exam-papers/:id/preview`：内联预览，不增加下载量。
- `GET /api/exam-papers/:id/download`：附件下载并原子增加下载量。

试卷列表和详情响应中的 `reward_revocable` 表示该投稿的经验奖励当前是否仍可撤销：仅当已发放奖励且尚未撤销时为 `true`。

管理员接口：

- `GET /api/admin/exam-papers?status=pending|published`
- `GET /api/admin/exam-papers/pending-count`
- `GET /api/admin/exam-papers/:id`
- `POST /api/admin/exam-papers/:id/approve`
- `POST /api/admin/exam-papers/:id/reject`
- `PATCH /api/admin/exam-papers/:id`
- `POST /api/admin/exam-papers/:id/unpublish`

功能错误统一为 `{"error":"中文说明","code":"机器错误码"}`。

远端上传相关错误码包括：`request_body_too_large`、`invalid_upload_session_request`、`privacy_confirmation_required`、`invalid_file_size`、`file_too_large`、`upload_session_not_found`、`upload_session_expired`、`upload_session_invalid`、`upload_receipt_invalid`、`upload_retry_exhausted`、`upload_unclaimed_quota_exceeded`、`exam_paper_pending_limit_reached`、`duplicate_exam_paper`、`storage_unavailable` 和 `client_upgrade_required`。两个上传会话 JSON 接口的请求体上限均为 64 KiB，超限返回 HTTP `413`。上传 token 只能对应一个上传会话和一个 `expected_size`；首次成功后，同一 token 的重放返回原始回执且不会重复落盘，其他 token 不得消费该会话。独立文件服务对同一会话最多记录 3 次上传失败，第 4 次在读取请求体和占用 PDF 校验槽位前返回 HTTP `429` 与 `upload_retry_exhausted`；失败事实会保留至授权过期后 24 小时，孤立且超过保留期的记录由维护任务清理，避免重启或维护意外重置有效重试限制。每个用户的未认领文件实际字节数和进行中上传预留量合计最多 100 MiB，超限同样在读取请求体前返回 HTTP `429` 与 `upload_unclaimed_quota_exceeded`。文件被认领、移入回收站或作为 7 天未认领文件清理后会持久释放配额。损坏的 `uploading` 或 `completed` 会话状态会按单份 20 MiB 保守计入配额，并由维护任务隔离为 `.corrupt` 文件；隔离文件保留 7 天后清理。`readonly-remote` 模式禁止创建新上传会话和旧 multipart 上传，但允许已创建会话提交回执完成入库。

文件存储维护结果除原有文件、回收站和会话清理计数外，还包含 `upload_failure_records_removed`、`corrupt_upload_session_records_quarantined`、`corrupt_upload_session_records_removed` 和 `upload_session_temp_files_removed`，分别表示过期孤立失败记录、当次隔离的损坏状态、过期隔离状态及崩溃遗留会话临时文件的清理数量。
