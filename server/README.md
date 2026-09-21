# SYLUlive Server

server/ 是沈理校园的 Go 后端，负责 App 账号、社区、竞赛、通知、反馈、管理、安全中心和公共服务。它还保留迁移期教务兼容入口，但新版个人教务访问不应默认依赖该路径。

## 架构边界

- App API 通过 Gin 提供 HTTP 接口，业务状态和权限数据存储在 PostgreSQL / pgvector。
- Nginx 负责公网 HTTPS、反向代理、静态文件和边缘限流；Go 服务默认监听 0.0.0.0:8080，生产不应绕过 Nginx 暴露该端口。
- Python RAG 服务处理允许的校园公共知识；个人教务凭据、Cookie 和原始学校响应不得进入 RAG。
- python-edu-service 是迁移期兼容组件。SCHOOL_AUTHORITY_RETIRED、SCHOOL_ACADEMIC_ROUTES_RETIRED 和客户端能力探测共同决定旧链路状态。

## 本地运行

准备 PostgreSQL 和环境变量后：

~~~bash
go run ./cmd
~~~

默认地址为 http://localhost:8080。也可以使用仓库根目录的 Docker Compose 运行完整依赖。

## 关键配置

生产启动前必须配置 JWT、数据库、安全中心和代理信任边界。安全相关变量包括：

- TRUSTED_PROXY_CIDRS
- SECURITY_EVENT_HMAC_SECRET
- SECURITY_BLOCK_ENABLED
- SECURITY_SOURCE_ATTRIBUTION_VALID_FROM
- SCHOOL_AUTHORITY_RETIRED
- SCHOOL_ACADEMIC_ROUTES_RETIRED

以 .env.example、配置加载代码和部署文档为准，不要把开发默认值直接带入生产。

## 数据库与迁移

迁移由服务端启动流程和仓库迁移脚本共同维护。生产执行前先备份 PostgreSQL，并在独立环境验证升级、回滚和安全表清理。不要直接修改生产表结构绕过迁移。

## 测试

~~~bash
go test ./...
go vet ./...
go build ./...
~~~

涉及认证、教务边界、上传、MCP、安全事件和管理员接口的修改，需要同时运行对应的集成测试。

## 接口文档

- [API 总览与路由状态](./API.md)
- [仓库部署总入口](../DEPLOY.md)
- [隐私数据台账](../docs/privacy-data-inventory.md)
