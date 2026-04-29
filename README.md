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
│   │   ├── models/       # 数据模型
│   │   └── services/     # 服务
│   ├── uploads/          # 上传文件
│   ├── go.mod
│   └── Dockerfile
├── client/               # Flutter 前端
│   ├── lib/
│   │   ├── models/       # 数据模型
│   │   ├── providers/    # 状态管理
│   │   ├── screens/      # 页面
│   │   ├── widgets/      # 组件
│   │   └── theme/        # 主题
│   ├── pubspec.yaml
│   └── Dockerfile
├── docker-compose.yml
└── README.md
```

## 环境要求

### 开发环境
- Go 1.21+
- Flutter 3.x+

### 生产环境
- Docker >= 20.10
- Docker Compose >= 2.0

## 配置说明

### 环境变量

| 变量名 | 说明 | 必填 |
|--------|------|------|
| JWT_SECRET | JWT密钥（至少32位随机字符串） | 是 |
| DSN | 数据库连接字符串 | 否（默认SQLite） |
| SUPER_ADMIN_DEFAULT_PASSWORD | 超级管理员初始密码 | 是 |
| UPLOAD_DIR | 文件上传目录 | 否（默认./uploads） |

### 生产环境部署

**重要：生产环境必须设置以下环境变量！**

1. 创建 `.env` 文件（不要提交到版本控制）：
```bash
cd server
cp .env.example .env
```

2. 修改 `.env` 中的敏感配置：
```bash
# 生成随机密钥
openssl rand -base64 32

# 编辑 .env 文件
JWT_SECRET=你的随机密钥
SUPER_ADMIN_DEFAULT_PASSWORD=你的强密码
```

3. 使用 Docker Compose 启动：
```bash
# 设置环境变量
export JWT_SECRET=你的随机密钥
export SUPER_ADMIN_DEFAULT_PASSWORD=你的强密码

# 启动服务
docker-compose up -d --build
```

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
# 启动所有服务（需先设置环境变量）
docker-compose up -d --build

# 查看服务状态
docker-compose ps

# 查看日志
docker-compose logs -f server

# 停止服务
docker-compose down
```

## 超级管理员

首次启动后，使用以下命令获取超级管理员账号信息：

```bash
# 查看服务日志
docker-compose logs server
```

超级管理员账号信息会在首次启动时输出。

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

## 安全建议

生产环境部署请注意：

1. **JWT密钥**：使用随机字符串（至少32位）
2. **超级管理员密码**：设置强密码
3. **数据库**：如使用MySQL/PostgreSQL，设置强密码
4. **HTTPS**：生产环境务必使用HTTPS
5. **环境变量**：不要将敏感信息提交到版本控制
6. **定期更新**：保持依赖和Docker镜像更新

## 数据库

应用启动时会自动创建SQLite数据库并执行迁移。

如需重置数据库：
```bash
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
