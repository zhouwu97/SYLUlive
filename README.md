# 沈理校园 - 校园互助社交应用

## 项目简介

沈理校园是一款面向高校学生的互助社交应用，提供水贴交流、校园集市、举报申诉等功能。

## 技术栈

### 后端
- Go 1.21+
- Gin (Web框架)
- GORM (ORM)
- SQLite (默认数据库)
- JWT (认证)
- bcrypt (密码加密)

### 前端
- Flutter 3.x+
- Provider (状态管理)
- Dio (HTTP客户端)
- cached_network_image (图片缓存)
- sqflite (本地数据库)
- flutter_secure_storage (安全存储)

## 项目结构

```
shenliyuan/
├── server/                # Go 后端
│   ├── cmd/              # 入口
│   ├── internal/         # 内部包
│   │   ├── config/       # 配置
│   │   ├── handlers/     # 处理器
│   │   ├── middleware/   # 中间件
│   │   ├── models/      # 数据模型
│   │   └── services/    # 服务
│   ├── uploads/          # 上传文件
│   ├── go.mod
│   └── Dockerfile
├── client/               # Flutter 前端
│   ├── lib/
│   │   ├── models/      # 数据模型
│   │   ├── providers/   # 状态管理
│   │   ├── screens/     # 页面
│   │   ├── widgets/     # 组件
│   │   └── theme/       # 主题
│   ├── pubspec.yaml
│   └── Dockerfile
├── docker-compose.yml
└── README.md
```

## 环境要求

### 开发环境
- Go 1.21+
- Flutter 3.x+
- Docker & Docker Compose (用于部署)

### 生产环境
- Docker >= 20.10
- Docker Compose >= 2.0

## 配置说明

### 后端环境变量

| 变量名 | 说明 | 默认值 |
|--------|------|--------|
| JWT_SECRET | JWT密钥 | shenliyuan-default-secret-change-in-production |
| DSN | 数据库连接字符串 | ./shenliyuan.db |
| SUPER_ADMIN_DEFAULT_PASSWORD | 超级管理员默认密码 | super123456 |
| UPLOAD_DIR | 文件上传目录 | ./uploads |

### 运行前配置

1. 复制环境变量示例文件（可选）：
```bash
cd server
cp .env.example .env
```

2. 修改 `.env` 中的敏感配置（生产环境必须修改）：
- `JWT_SECRET`: 设置为随机字符串
- `SUPER_ADMIN_DEFAULT_PASSWORD`: 修改默认密码

## 本地运行

### 后端

```bash
cd server
go mod tidy
go run cmd/main.go
```

服务器将在 http://localhost:8080 启动。

### 前端

```bash
cd client
flutter pub get
flutter run
```

### Docker 部署

```bash
# 启动所有服务
docker-compose up -d --build

# 查看服务状态
docker-compose ps

# 查看日志
docker-compose logs -f server

# 停止服务
docker-compose down
```

## 默认账号

| 角色 | 用户名 | 密码 |
|------|--------|------|
| 超级管理员 | super_admin | super123456 |
| 管理员 | admin | admin123 |
| 测试用户 | 2024001 | test123456 |

## API 文档

### 认证
- `POST /api/register` - 注册
- `POST /api/login` - 登录
- `POST /api/change_password` - 修改密码（需认证）

### 用户
- `GET /api/user/profile` - 获取个人资料（需认证）
- `PUT /api/user/profile` - 更新个人资料（需认证）
- `PUT /api/user/avatar` - 更新头像（需认证）
- `PUT /api/user/background` - 更新背景图（需认证）
- `PUT /api/user/nightmode` - 更新夜间模式（需认证）

### 帖子
- `GET /api/posts` - 获取帖子列表
- `POST /api/posts` - 创建帖子（需认证）
- `GET /api/posts/:id` - 获取帖子详情
- `PUT /api/posts/:id` - 更新帖子（需认证）
- `DELETE /api/posts/:id` - 删除帖子（需认证）

### 回复
- `GET /api/posts/:id/replies` - 获取回复列表
- `POST /api/posts/:id/replies` - 创建回复（需认证）
- `DELETE /api/replies/:id` - 删除回复（需认证）

### 私信
- `GET /api/messages/conversations` - 获取会话列表（需认证）
- `GET /api/messages/conversations/:id` - 获取消息列表（需认证）
- `POST /api/messages/:user_id` - 发送消息（需认证）

### 公告
- `GET /api/announcements` - 获取公告列表
- `POST /api/announcements` - 创建公告（需管理员）
- `PUT /api/announcements/:id` - 更新公告（需管理员）
- `DELETE /api/announcements/:id` - 删除公告（需管理员）

### 举报
- `POST /api/reports` - 创建举报（需认证）
- `GET /api/reports` - 获取举报列表（需管理员）
- `PUT /api/reports/:id/handle` - 处理举报（需管理员）

### 申诉
- `POST /api/posts/:id/appeal` - 创建申诉（需认证）
- `GET /api/appeals` - 获取申诉列表（需认证）
- `POST /api/appeals/:id/vote` - 投票（需认证）

### 管理员邀请
- `GET /api/admin/candidates` - 获取候选人列表（需认证）
- `POST /api/admin/invite/:user_id` - 邀请用户（需管理员）
- `GET /api/user/invitations` - 获取待处理邀请（需认证）
- `POST /api/user/invitations/:id/accept` - 接受邀请（需认证）
- `POST /api/user/invitations/:id/reject` - 拒绝邀请（需认证）

### 超级管理员
- `GET /api/super/users` - 获取所有用户
- `PUT /api/super/users/:id/role` - 修改用户角色
- `PUT /api/super/users/:id/credit` - 修改用户诚信度
- `POST /api/super/users/:id/reset_password` - 重置用户密码
- `DELETE /api/super/users/:id` - 删除用户
- `GET /api/super/stats` - 获取系统统计

### 文件上传
- `POST /api/upload` - 上传单个文件（需认证）
- `POST /api/upload_multiple` - 批量上传文件（需认证）

## 安全警告

**重要：生产环境部署前必须修改以下配置：**

1. **JWT密钥**：修改 `JWT_SECRET` 为随机字符串（至少32字符）
2. **超级管理员密码**：修改 `SUPER_ADMIN_DEFAULT_PASSWORD`
3. **数据库**：如使用MySQL，确保设置强密码
4. **端口映射**：如不需要外部访问，移除 docker-compose.yml 中的端口映射
5. **定期更新**：保持 Docker 镜像和依赖的更新

## 数据库

应用启动时会自动创建SQLite数据库并执行迁移。

如需重置数据库：
```bash
# 停止服务并删除数据
docker-compose down -v
rm -f server/shenliyuan.db
```

## 开发说明

### 添加新的API端点

1. 在 `internal/models/` 添加数据模型
2. 在 `internal/handlers/` 添加处理器
3. 在 `cmd/main.go` 注册路由

### 前端页面开发

1. 在 `lib/models/` 添加数据模型
2. 在 `lib/providers/` 添加状态管理
3. 在 `lib/screens/` 添加页面
4. 在 `lib/widgets/` 添加通用组件

## 许可证

MIT License