# 沈理校园 (SYLUlive) Backend API Documentation

本文件旨在提供沈理校园后端的 HTTP API 接口概览。所有的接口均基于 RESTful 风格设计，通过 JSON 格式进行数据交互。

## 安全中心预警来源

`GET /api/admin/security/events` 与 `GET /api/admin/security/events/:id` 延续管理员鉴权；普通用户不可访问。`source_key` 仍只提供给超级管理员，用于既有 HMAC 来源封禁。

预警新增 `source_ip`、`source_ip_status`、`source_region`、`source_region_status`。IP 仅在可信来源且该预警已保存有效密文时返回，状态为 `available`；`not_recorded` 表示历史记录或普通审计未记录 IP，`untrusted` 表示来源归因不可信，`unavailable` 表示密文无法读取。归属地是国家／省／市的离线查询结果，不含经纬度；状态为 `resolved`、`private`、`local`、`reserved`、`unknown`、`database_unavailable` 或 `database_error`。缺少 IP 时不猜测归属地。

列表继续返回 `items`、`total`、`page`、`limit`，客户端支持加载后续页及失败重试。统计接口 `protection.security_ip_location` 和 `security_ip_location_note` 报告本地 IPv4／IPv6 库是否可用。数据库缺失只影响归属地，不能伪装为归属地正常，也不阻断事件采集。

## 基础信息

- **基础路由 (Base URL)**: `/api`
- **内容类型 (Content-Type)**: `application/json` (除文件上传外)
- **鉴权方式 (Authentication)**: 大部分接口依赖 JWT 进行鉴权，通过 `Authorization: Bearer <token>` 传递。

### 社区页面上下文（只读增量）

现有 `POST /api/ai/runs` 的 `context.context_refs` 增加 `post`、`reply` 两种引用，ID 为十进制字符串。仅在服务端开启 `AI_COMMUNITY_READ_ENABLED` 且相应读取工具已注册时接受；继续使用当前 JWT 身份和现有 AI 额度。

~~~json
{
  "client_request_id": "7ad76984-81e7-45fd-b4c8-f5c7319f971b",
  "message": "请阅读这条讨论，概括大家的意见",
  "context": {
    "entrypoint": "post_detail",
    "context_refs": [{"type": "post", "id": "123"}]
  }
}
~~~

帖子引用在生成前读取当前正文和首批评论；评论引用读取评论及所属帖子、适用的根评论与精确回复目标。更多评论由只读工具分页获取。隐藏、删除、非水帖或投票等范围外来源返回 HTTP 422 / `invalid_agent_context`，与不存在的 ID 一致，不返回私有内容。通过验证后状态改变，预读取仍重新查询；预读取失败沿用现有 Run 失败/不完整结果处理，不根据客户端对象猜测事实。

此接口不创建社区评论，不改变真人浏览统计；不会自动查询私信或上传图片。Flutter 页面入口和审核发布 UI 尚未在该增量中交付。

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
| `POST` | `/api/login_edu` | 已退役，固定返回 `410` |
| `POST` | `/api/register_with_edu` | 已退役，固定返回 `410` |
| `POST` | `/api/password/email/code` | 发送邮箱密码找回验证码 |
| `POST` | `/api/password/email/reset` | 使用邮箱验证码重置密码 |
| `POST` | `/api/forgot_password` | 旧教务找回入口，已退役，固定返回 `410` |
| `POST` | `/api/change_password` | 修改密码 (需 JWT) |

## 2. 用户与个人中心 (User)

大部分需 JWT 鉴权。

| Method | Endpoint | Description |
|---|---|---|
| `GET` | `/api/user/profile` | 获取当前用户资料 |
| `GET` | `/api/user/account-security` | 当前账号的私有安全资料；完整邮箱仅在此返回 |
| `POST` | `/api/user/email/code` | 向目标邮箱发送绑定或换绑验证码；省略 `purpose` 时按账号实际绑定状态推导 |
| `PUT` | `/api/user/email` | 使用邮箱验证码和当前 App 密码绑定或换绑邮箱，成功签发新会话 |
| `DELETE` | `/api/user/email` | 使用当前 App 密码解除邮箱；唯一登录方式不能解除 |
| `PUT` | `/api/user/profile` | 更新个人资料 (昵称、性别等) |
| `PUT` | `/api/user/avatar` | 更新头像 URL |
| `PUT` | `/api/user/background`| 更新个人主页背景 |
| `GET` | `/api/user/:id` | 获取指定用户信息 |
| `POST`| `/api/user/checkin` | 用户每日签到 |
| `POST`| `/api/user/checkin/makeup` | 使用补签卡补签本月过去的未签到日期 |
| `GET` | `/api/user/checkin/status` | 获取签到状态 |
| `GET` | `/api/user/checkin/calendar?month=YYYY-MM` | 获取指定月份的签到记录 |

AstrBot 的独立授权接口为 `GET /api/integrations/v1/me/checkin`（本人状态）与 `POST /api/integrations/v1/me/checkin`（本人当日签到），二者需本人明确批准 `checkin:write`。不接受用户编号、日期、补签或经验参数；与 App 共用同日事实、奖励及幂等，撤权与签到串行复核。请求体仅允许空或 `{}`，拒绝额外字段／查询参数；返回日期、连续天数、本次奖励等最小数据，不返回学号或经验总额。

公开工具接口 `GET /api/integrations/v1/public/community/{posts,posts/:id,posts/:id/replies,replies/:id/context,stickers,sections}` 无需账号令牌，仍按固定字段／可见状态过滤、限流且不增加浏览量。原有带授权路径保留兼容；本人资料／签到／草稿不属于该公开命名空间。食堂、校园资讯 `/api/campus/articles`、学校校历 `/api/campus-calendars/current` 沿用既有公开接口。
| `POST`| `/api/user/:id/follow` | 关注指定用户 |
| `DELETE`| `/api/user/:id/follow`| 取消关注指定用户 |
| `GET` | `/api/user/:id/posts` | 获取指定用户发布的帖子 |

每段连续签到第 7 天获得首张补签卡，此后每隔 14 天再获得 1 张，即该段第 7、21、35、49 天各发 1 张；第 14 天不额外发卡。每次断签后重新开始均按此规则计算，已获得的卡保留。补签接续连续天数时按同一规则重算奖励，若合并两段记录导致理论奖励减少，已发奖励转为保留额度，不额外追扣。使用时消耗 1 张，仅可补签本月今天之前的未签到日期；重复请求不重复发卡或扣卡，签到经验规则保持不变。

## 3. 教务系统 (Edu)

教务接口处于本地化迁移期，必须区分路由状态：

- **Active**：新版客户端可以使用的账号、社区、公共服务和用户明确授权的结构化快照接口。
- **Migration compatibility**：仅供旧客户端迁移、回归或受控内部环境使用的教务兼容接口。
- **Retired**：已退役并固定返回 `410` 的旧登录、注册或教务入口；客户端必须依据能力探测停止调用。

个人教务访问的目标路径是客户端直接连接学校系统。迁移期兼容服务是否加载由 `SCHOOL_AUTHORITY_RETIRED` 控制，Go 服务端旧教务路由还受 `SCHOOL_ACADEMIC_ROUTES_RETIRED` 控制；两者均不能在文档中被默认当作生产 Active 能力。

| Method | Endpoint | Description |
|---|---|---|
| `POST` | `/api/edu/bind` | **Migration compatibility**：旧客户端教务绑定；生产状态以开关为准 |
| `DELETE` | `/api/edu/bind` | **Migration compatibility**：撤销迁移期绑定 |
| `GET` | `/api/edu/status` | **Migration compatibility**：查询迁移期绑定状态 |
| `POST` | `/api/edu/session/resume` | **Migration compatibility**：恢复迁移期教务会话 |
| `POST` | `/api/edu/courses` | **Migration compatibility**：旧客户端课表读取 |
| `POST` | `/api/edu/grades` | **Migration compatibility**：旧客户端成绩读取 |
| `POST` | `/api/exam/extract` | **Migration compatibility**：旧教务考题提取能力 |
| `POST` | `/api/erke/scores` | **Migration compatibility**：旧二课读取能力 |

旧登录、注册和密码找回入口 `/api/login_edu`、`/api/register_with_edu`、`/api/forgot_password` 等已退役并返回 `410`，不应继续接入新客户端。

### Active：已授权二课快照

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

楼中楼请求传 `parent_reply_id`（线程根）与 `reply_to_reply_id`（实际点击的评论）。服务端校验两者属于同一线程并推导 `reply_to_user_id`，回复通知仅发给实际对象；客户端传入的用户 ID 不作为通知依据。回复响应中的 `reply_to_name` 为对象的公开昵称，列表、子回复分页、定位和创建响应均携带；客户端持续展示“回复 @昵称”，不要求把昵称写入正文。

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
| `POST` | `/api/teachers/:id/rate` | 兼容入口：转入课程评价状态机 |
| `DELETE` | `/api/teachers/rating/:id` | 删除自己的教师评价 |
| `POST` | `/api/course-evaluations` | 创建课程评价（重复目标返回 409） |
| `PATCH` | `/api/user/course-evaluations/:id` | 更新课程评价（必须携带当前 `revision`） |
| `GET` | `/api/majors` | 获取专业评价列表 |
| `GET` | `/api/majors/:id` | 获取专业详情及评价 |
| `POST` | `/api/majors/:id/rate` | 评价专业 |
| `DELETE` | `/api/majors/rating/:id` | 删除自己的专业评价 |
| `GET` | `/api/canteens` | 获取食堂评分列表（Bayesian 排序；含 `dish_count`/`dish_photo_count`） |
| `GET` | `/api/canteens/:id?review_sort=best\|latest&review_filter=all\|with_image\|high\|low` | 公开获取食堂详情及评价；登录时附带个人评价/投票状态 |
| `POST` | `/api/canteens/:id/rate` | 评价食堂（需登录并绑定教务） |
| `PUT` | `/api/canteens/ratings/:ratingId/vote` | 给食堂评价点赞/点踩/取消投票，不能给自己的评价投票 |
| `PUT` | `/api/canteens/:id/image` | (管理员) 修改食堂封面图片 |
| `POST` | `/api/canteens` | (需登录) 提交新食堂，进入待审核；`verified=false` 不公开，管理员收到站内通知。请求体 `{"name", "image", "location_area", "location_floor"}`；`location_area` 可选值 `一食堂`/`二食堂`，`location_floor` 可选值 `一楼`/`二楼`（旧客户端可省略） |
| `GET` | `/api/canteens/pending` | (管理员) 待审核食堂列表（含 `creator_name` 提交人昵称与 `location_area`/`location_floor` 位置标签） |
| `POST` | `/api/canteens/:id/approve` | (管理员) 通过审核，文件转 `public`，通知提交者；提交者获得 10 经验奖励（幂等，仅用户提交，响应含 `exp_awarded`） |
| `DELETE` | `/api/canteens/:id/pending` | (管理员) 驳回并删除待审提交，可带 `{"reason": "..."}` 通知提交者 |
| `POST` | `/api/canteens/:id/offline` | (管理员) 下架已公开食堂（历史数据保留）；如有未收回的提交奖励经验则收回，经验扣至下限 0 |
| `POST` | `/api/canteens/:id/online` | (管理员) 恢复已下架食堂；返还此前因下架收回的提交奖励经验 |
| `DELETE` | `/api/canteens/:id` | (管理员) 永久删除食堂；如有未收回的提交奖励经验则收回 |

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
| `POST` | `/api/canteens/:canteenId/dish-photos` | 已退休，返回 `410 dish_submission_retired`；请改用食堂评价关联菜品实拍 |
| `GET` | `/api/canteens/dish-photos/:photoId` | (管理员) 查看实拍详情（含上传者信息） |
| `POST` | `/api/canteens/dish-photos/:photoId/archive` | (管理员) 下架实拍（事后治理，业务隐藏，回收孤儿文件公开权限） |
| `PATCH` | `/api/canteens/dishes/:dishId` | (管理员) 重命名或隐藏菜品 |
| `POST` | `/api/canteens/dishes/:dishId/merge` | (管理员) 合并疑似重复菜品到已有菜品并创建 alias |

**实拍提交迁移**

独立菜品投稿接口 `/dish-photos`、`/dish-submissions` 和菜品 `resubmit` 已退休，统一返回
`410` 与 `code=dish_submission_retired`。客户端应通过 `POST /api/canteens/:id/reviews`
提交食堂评价，在 `dishes[].dish_name` 中关联菜品，并在 `dishes[].photo_file_ids` 中绑定实拍文件；
评价提交流程负责菜品归一化、直接创建 active 菜品和 approved 实拍。

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
| `POST`| `/api/notifications/read-selected` | 以当前登录用户为接收者。支持 `{"ids":[通知ID]}`（最多100个），或成功打开目标回复后发送 `{"post_id":帖子ID,"reply_id":回复ID}`；只消费匹配的回复通知 |
| `GET` | `/api/user/likes/received` | 当前用户的帖子、评论收到的历史点赞；`limit` 默认30、最大50，`cursor` 为上一页返回的点赞ID。响应 `{items,has_more,next_cursor}`，每项含 `id,user_id,nickname,avatar,target_type,target_id,post_id,post_title,created_at`；过滤自赞、取消的赞、已删除/受限内容和注销账号 |

通知已读接口在原有响应上附加 `read_receipt`：`recipient_user_id` 表示接收账号，单条/目标回复读取返回实际归属该账号的 `ids` 和 `reply_ids`，全部已读返回 `all_before_id`。全部已读只处理该水位之前的通知，新产生的通知保持未读。旧客户端可忽略此附加字段。Android 用回执清理系统通知并阻止延迟重放；新回复推送附带 `notification_id`，使用 `reply_notifications_v1` 高优先级渠道，仍遵从用户的系统通知权限。
| `POST` | `/api/notifications/replies/read` | 将当前账号全部回复通知标为已读，包含未加载分页；不影响其他类型通知。旧服务端无此路径返回 `404`，客户端保留提醒且提示重试，不降级为全部通知已读 |

## 6.1 统一搜索 (Search)

| Method | Endpoint | Description |
|---|---|---|
| `GET` | `/api/search?type=posts&q=关键词&sort=relevance` | 按标题或正文搜索帖子，支持 relevance/latest/hot |
| `GET` | `/api/search?type=users&q=用户ID或昵称&sort=relevance` | 公开搜索仅支持精确用户 ID 或昵称，支持 relevance/newest |

`q` 去除首尾空白后须为 1 至 64 个 Unicode 字符，支持单字符关键词（例如 `2`、`好`）和单数字用户 ID。不能只包含 `%`、`_`、`*`、`?`、`\` 等通配符。无效输入返回 `400`，正常搜索但无匹配内容返回 `200` 和空 `items`。匿名搜索每个来源每分钟最多 30 次，超限返回 `429` 和 `Retry-After: 60`。

校园资讯 `GET /api/campus/articles?q=关键词` 同样支持 1 至 64 个字符；省略 `q` 时仍返回未按关键词筛选的列表。

## 7. 管理员与超级管理员 (Admin)

需要特殊角色权限 (Admin/SuperAdmin)。

**管理员管理 (Admin)**
| Method | Endpoint | Description |
|---|---|---|
| `GET` | `/api/admin/members` | 获取当前管理员列表，返回用户 ID 与学号/登录账号 |
| `GET` | `/api/admin/candidates` | 管理员候选列表，`q` 支持用户 ID、学号/账号或昵称；分页保留候选资格筛选 |
| `GET` | `/api/admin/candidates/stats` | `edu` 为有有效云端教务配置、可信身份或旧教务授权的现存用户去重数，`other=total-edu`；不表示身份验证人数 |
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

管理用户摘要中的 `student_id` 依次取可信身份学号、最近更新的有效云端配置学号、旧登录账号字段。`academic_configured` 仅表示存在有效配置，`student_verified` 仍按可信身份独立判断；登记配置不授予学生权限。搜索包含所有有效云端配置学号，已删除配置不用于搜索或展示。本机连接尚未同步时服务端无法据此登记；管理接口不返回学校密码、Cookie 或会话，公开用户接口也不增加学号。

### 安全中心

| Method | Endpoint | 权限与行为 |
|---|---|---|
| `GET` | `/api/admin/security/overview?range=24h` | 管理员；支持 `1h`、`24h`、`7d`，返回统计与防护运行状态 |
| `GET` | `/api/admin/security/events` | 管理员；按 `severity`、`status`、`actionable` 筛选，返回 `items/total/page/limit` |
| `GET` | `/api/admin/security/events/:id` | 管理员；单条事件详情 |
| `POST` | `/api/admin/security/events/:id/resolve` | 管理员；仅从 `active` 标记为已处理，备注可选，最多 500 个 Unicode 字符 |
| `POST` | `/api/admin/security/events/:id/false-positive` | 管理员；仅从 `active` 标记为误报，备注规则同上 |
| `GET` | `/api/super/security/blocks?page=1` | 超级管理员；每页 200 条生效封禁，同一操作按 `group_id` 归组 |
| `POST` | `/api/super/security/blocks` | 超级管理员；`route/account/all` 作用域，`all` 必须 `confirm_global=true`；时长 15/60/1440 分钟；原因最多 200 个 Unicode 字符 |
| `DELETE` | `/api/super/security/blocks/:id` | 超级管理员；一次解除同一操作组全部封禁 |

事件列表默认每页 50 条，最多 100 条；事件和封禁页码最多 10000。事件按最后发生时间、ID 倒序稳定排序。正常验证码、正常改密等流水通过 `actionable=false` 区分，默认待办使用 `actionable=true&status=active`。普通管理员只取得脱敏来源指纹，完整来源键仅返回给超级管理员。

事件处置请求接受 `{"note":"处理说明"}`，兼容空请求体；非法 JSON 返回 `400`，不存在返回 `404`，已被其他请求处置返回 `409/security_event_already_handled`，保留第一次处理结论和审计。数据库故障返回 `500`。客户端收到冲突后刷新列表。防护数据加载失败时不沿用旧的健康状态；缺失的运行态保持“未验证”。

## 8. 公共服务 (Public & AI)

| Method | Endpoint | Description |
|---|---|---|
| `POST` | `/api/upload` | 上传单张图片/文件 |
| `POST` | `/api/upload_multiple` | 逐项返回结果的图片批量上传，1–9 张 |
| `GET` | `/api/announcements/active` | 获取活跃系统公告 |
| `POST` | `/api/feedback` | 提交产品功能建议或Bug |
| `POST` | `/api/v1/question/solve` | 触发大模型 AI 解答题目接口 |

> **注**: 以上仅为摘要级接口列表。请求载荷 (Body) 和返回体结构请参考对应处理器 (Handlers) 的 Go 源码定义。

图片上传接受 JPG、PNG、GIF，单张最多 10 MiB，最长边不超过 12000 像素且总像素不超过 5000 万；先校验尺寸，再解码验证图片内容。客户端选择后即可上传，响应继续返回 `file_id`、`url`，发帖只需认领已上传的文件。上传后仍为 `temporary/private`，未发出的图片沿用临时文件留存与配额规则；成功重传相同图片会刷新当前用户授权的临时保留窗口，文件创建时间与访问权限保持不变，正在删除的文件仍拒绝复用。发帖认领后才生成公开预览任务。GIF 保留动画原文件，预览使用静态首帧；PNG 预览保留透明度并采用无损编码压缩。

预览沿用 `_v1_thumb`、`_v1_medium`、`_v1_viewer` 路径与原图回退。普通图片的长边上限仍为 480、1280、2048；长宽比达到 3 的长图改按短边 320、960、1280 和总像素 150 万、500 万、1000 万的双重预算等比缩放，避免长截图文字被固定长边缩成窄条，不放大小图，不为达到固定字节数强行降清晰度。已有 ready 预览和原图保持不变，无需迁移或批量重编码。

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


## 个人 AstrBot 集成（默认关闭）

启用与真实联调状态见 [插件 README](../astrbot_plugin_sylulive/README.md)。主模型在人部署的 AstrBot，业务仍由 Go 统一校验。以下 OAuth/集成/连接管理接口绕过全局响应幂等缓存，不能缓存凭证、nonce 或重放旧来源；动作使用业务内 `operation_id`/`action_id`。

| 路径 | 身份 | 用途 |
| --- | --- | --- |
| `POST /api/oauth/device_authorization` | 公开客户端 `client_id=sylulive-astrbot` | URLencoded：`installation_id` UUID、自报名称、scope；返回 RFC8628 字段，有效10分钟 |
| `POST /api/oauth/token` | 设备 secret 或 refresh token | URLencoded；device grant 或 refresh grant。access 10分钟、refresh闲置7天、绝对30天；旧 refresh 重用撤销该授权 |
| `POST /api/oauth/revoke` | 所撤凭证 | RFC7009，同属授权一并撤销；不会注销 App 登录 |
| `GET /api/connected-apps` | App 登录 | 本人的连接列表，不返回凭证 |
| `POST /api/connected-apps/device-requests/lookup` | App 登录且10分钟内真实登录 | JSON `user_code`，返回待核对范围与一次性确认 nonce |
| `POST /api/connected-apps/device-requests/:id/decision` | 同上 | `allow`、`scopes`、`confirmation_nonce`；替换还须旧 `replace_binding_id` 与 `expected_epoch` |
| `POST /api/connected-apps/:id/revoke` | 本人 App 登录 | 立即撤销，无近期登录额外门槛 |
| `GET /api/integrations/v1/binding` | scoped Bearer | `profile:read_minimal`，账号 ID 与昵称、授权范围 |
| `GET /api/integrations/v1/community/posts` | `community:read` | `query`、`after_id`、`limit`（1至20），最近/搜索公开普通水帖 |
| `GET /api/integrations/v1/community/posts/:id` | 同上 | 文字详情、`post_id`、`source_version`；`data` 就是帖子 DTO |
| `GET /api/integrations/v1/community/posts/:id/replies` | 同上 | 评论分页，`after_id` 与 `limit` |
| `GET /api/integrations/v1/community/replies/:id/context` | 同上 | 线程根和精确目标；删除正文不恢复 |
| `GET /api/integrations/v1/community/stickers` | 同上 | `query`、`limit`、`after_sticker_id`，内置表情 ID 与标签 |
| `GET /api/integrations/v1/community/sections` | 同上 | 活跃版块 slug 与标题 |
| `GET /api/integrations/v1/me/public-posts` | `content:read_own_public` | 服务端从授权推导本人；不接收 owner 参数，仅正常普通社区帖子 |
| `POST /api/integrations/v1/actions` | `community:propose` | 只创建草稿，不能发布；需开启提案开关 |
| `GET /api/integrations/v1/actions/:id` | `actions:read_own` | 本授权动作，不能得到发布确认 nonce；来源变更时阻断旧草稿正文 |
| `GET /api/connected-apps/actions/:id` | 本人 App 登录且近期认证 | 草稿预览与5分钟确认 nonce；本人官网使用 |
| `POST /api/connected-apps/actions/:id/decision` | 同上 | `allow`、`draft_version`、`payload_hash`、`confirmation_nonce`；发布需独立开关 |

助手凭证不能调用普通 App API，App JWT 也不能调用集成 API。允许的 scope 为 `profile:read_minimal community:read content:read_own_public actions:read_own community:propose` 的子集；提案必须同时批准读取和结果查询。普通教务本地声明不满足可信核验要求；无权限失败返回稳定 `code`，OAuth 错误使用 `error`。所有含授权数据的响应设置 `Cache-Control: no-store`。

评论草稿 JSON：

```json
{"operation_id":"YOUR_UUID","kind":"reply","post_id":123,"source_version":"刚读取的64位版本摘要","content":"正文","sticker_id":"可选白名单表情","reply_to_reply_id":0,"reply_source_version":""}
```

精确回复需真实目标 ID 和目标 `source_version`；父线程与通知用户由服务器推导，不接受伪造 author、role 或 parent。发帖草稿使用 `kind=post`、有效 `post_type`、`title`（可空）、`content`，不接受评论字段、附件、市场/投票/公告操作。响应是 `action_id`、`state`、`review_uri`、`expires_at`，不表示发布完成。单 owner 每24小时最多30个新草稿、20次正式助手发布，并计入原有发帖/评论额度；发布事务内完成当前权限、来源/版块/禁言、额度、内容、计数、动作状态与审计的一致性更新。统计变化不影响来源版本，内容变化需要重读重建。助手评论与站内回复通知原子提交，按评论与接收人去重，自回复不提醒；精确回复通知目标评论作者。提交后复用现有推送流程，外部投递失败不回滚已提交评论，也不宣称必达。创建/删除/评论治理/恢复按先帖子后评论顺序加锁。已使用旧refresh在摘要保留期内重放仍撤销同一授权，不因旧闲置期限过期而跳过检测。无奖励、无后台队列、无无人确认发布。

### 集成公开阅读字段与排名

`GET /api/integrations/v1/community/posts` 新增 `sort=newest|likes|replies`（默认 newest）、`cursor`。最新按 ID 倒序用 `next_after_id`；排名按真实计数与 ID 倒序用 `next_cursor`，不与 after_id 混用，游标绑定排序和查询条件。错误组合返回 422，统计变化不保证列表快照。

公开帖子和正常评论新增 `author.nickname`、`like_count`、`images`；帖子含 `reply_count`。图片只包含当前可见内容关联且 public/active 的图片 URL、MIME、尺寸与序号，不返回上传者、存储元数据或私有文件。详情正文上限 10000 字；列表仍为 600 字摘要，评论分页不变。新增展示字段不参与草稿 source_version，统计／改名不使草稿失效。删除评论仍只留墓碑；所有路径保留 scope、当前资格和授权复核，不增加浏览量。

AstrBot 食堂工具直接匿名复用现有 `/api/canteens/rankings`、`/search`、`/:id/dishes`、`/:id/dishes/:dishId`；不新增私有资料、学校登录或私信 scope。
