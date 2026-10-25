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
- SECURITY_IP_V4_DB_PATH、SECURITY_IP_V6_DB_PATH（离线 IP 归属地库）
- SCHOOL_AUTHORITY_RETIRED
- SCHOOL_ACADEMIC_ROUTES_RETIRED

以 .env.example、配置加载代码和部署文档为准，不要把开发默认值直接带入生产。

### 安全预警 IP 与离线归属地

仅需管理员处置的预警保存 IP 密文；普通登录、验证码等审计流水仍只保存来源摘要。管理员安全接口可查看预警 IP 和国家／省市归属地，普通用户接口不返回这些字段。历史摘要不可逆，升级前的记录显示「未记录 IP」。

本地运行前在 `server/` 执行 `go run ./cmd/install_geoip`，安装并校验固定版本的 IPv4／IPv6 离线库。Docker 构建自动执行相同步骤并携带数据文件；运行期间不下载数据，也不会向第三方发送用户 IP。systemd／独立二进制发布须一并携带 `data/geoip/`，或用上述环境变量指定可读路径。缺失或损坏的库会在安全中心显示不可用／降级，其他安全采集与处置继续工作。来源、校验值、许可与更新方式见 [离线库说明](data/geoip/README.md)。

## 数据库与迁移

迁移由服务端启动流程和仓库迁移脚本共同维护。生产执行前先备份 PostgreSQL，并在独立环境验证升级、回滚和安全表清理。不要直接修改生产表结构绕过迁移。

签到补签卡规则见 [用户接口说明](API.md#2-用户与个人中心-user)。迁移 `20261025_04_checkin_makeup_card_schedule` 在启动时按历史签到事实重建「每段连续签到第 7 天首张、之后每隔 14 天再发一张」的汇总，保留额外发放数量并按补签事实保留已使用数量，不修改用户经验或经验流水。若旧规则或补签合并前已经发放的奖励多于重建结果，差额转入 `makeup_cards_granted` 保留，后续重建不重复补发。整批重建与迁移标记在同一事务内，可失败重试；也兼容已存在 `20261025_03_checkin_weekly_makeup_cards` 标记的数据。升级期间应停止旧版实例写入签到；回退旧版前应同步恢复备份中的签到事实和汇总，避免旧版周期与新版余额混用。

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
