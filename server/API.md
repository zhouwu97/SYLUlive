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
| `GET` | `/api/user/checkin/status` | 获取签到状态 |
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

## 5. 榜单与评价 (Ratings)

提供教师避雷榜、专业榜、食堂榜的评价体系。

| Method | Endpoint | Description |
|---|---|---|
| `GET` | `/api/teachers` | 获取教师榜单列表 |
| `GET` | `/api/teachers/:id` | 获取教师详情及评价 |
| `POST` | `/api/teachers/:id/rate` | 评价教师 |
| `GET` | `/api/majors` | 获取专业评价列表 |
| `GET` | `/api/canteens` | 获取食堂评分列表 |

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
| `GET` | `/api/search?type=users&q=账号或昵称&sort=relevance` | 按账号或昵称搜索用户，支持 relevance/newest |

## 7. 管理员与超级管理员 (Admin)

需要特殊角色权限 (Admin/SuperAdmin)。

**管理员管理 (Admin)**
| Method | Endpoint | Description |
|---|---|---|
| `GET` | `/api/admin/members` | 获取当前管理员列表 |
| `POST` | `/api/admin/invite/:id`| 邀请指定用户成为管理员 |
| `POST` | `/api/teachers/admin/:id/vote-remove` | 投票罢免管理员 |

**超级管理员 (Super Admin)**
| Method | Endpoint | Description |
|---|---|---|
| `GET` | `/api/super/users` | 全局用户风控管理列表 |
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
