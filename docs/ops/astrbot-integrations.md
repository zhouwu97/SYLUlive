# AstrBot 集成发布入口

业务与安装契约以 [插件 README](../../astrbot_plugin_sylulive/README.md) 为准；生产执行遵循 [DEPLOY.md](../../DEPLOY.md)、[后端](backend.md)、[官网](website.md) 与 [回滚](rollback.md)。不能把本地验证当成生产放行。

## 首次只读试运行范围

发布 Go 授权/读取 API 和 Web 的 `/web/connected-apps`。QQ 协议端和 AstrBot 留在用户本机。用户自行在官方网页登录、核对设备代码和同意 scope；操作者不能代填学校密码、伪造教务资格或替用户批准授权。

首轮配置：

```dotenv
INTEGRATIONS_ENABLED=true
INTEGRATION_PROPOSALS_ENABLED=false
INTEGRATION_OWNER_PUBLISH_ENABLED=false
INTEGRATION_PUBLIC_ORIGIN=https://sylulive.online
```

插件 `server_origin` 同为 `https://sylulive.online`、`allow_proposals=false`。生产数据库和服务开关只能在维护者明确批准本次发布、备份与门禁就绪后修改。后两项开关不能因读取验收通过自动开启。

## 发布前

1. 固定不可变候选 SHA，完整测试并按开发规范核验 CI/安全证据。新增 `astrbot-plugin` job 使用真实 AstrBot SDK；PostgreSQL job 显式运行 `TestIntegration` 并提供本机专用测试 DSN，不能让这些测试因缺环境静默跳过。
2. 保存当前二进制、运行环境、有效 Nginx 配置及源码工作树差异。现场已有未提交修改时停止直接部署，先确认其行为被候选保留；不得使用强制重置丢弃它。
3. 只读统计教务核验分布。插件只认可 `school_profile` 且版本为 `v1` / `undergraduate-preverify-v1`；统计是绑定记录数，不是保证可授权人数。用户状态、当前协议和近期登录仍在授权时复核。
4. 对生产数据库做一致性备份，记录恢复入口与校验值。新版本启动会增加集成凭证/动作/审计/限流表、内容来源列和刷新会话的认证时间列；关开关不等于没有迁移。
5. 检查部署入口的源目录、运行目录和 Go 版本。后端使用 `deploy/deploy-shenliyuan <SHA>`。现有官网根目录与客户端产物保持隔离；Web 只发布 `/web/` 子路径并保留已有首页、分享与 API 配置。

## 验收

- `/health`、`/version` 正常，版本 SHA 与候选一致，原 App 登录/刷新及普通社区读取保留。
- 未认证访问 `/api/integrations/v1/binding` 返回身份错误，不能是 404 或无保护数据。
- `/web/connected-apps` 载入正确发布物，静态资源和路由可恢复；缺资格、近期登录失效、网络错误均显示实际失败。
- 用户在 QQ 执行 `/sylu-connect`，在官网确认后执行 `/sylu-status`，随后读取公开帖子；记录真实 `post_id`，确认浏览量未增加、无私有字段。
- 用户撤销连接后旧凭证被拒绝；不通过改提示词或本机白名单绕过服务端授权。
- 试运行不测试线上发帖/评论；写入能力另行灰度并逐次本人确认。

## 回滚

先关闭 `INTEGRATIONS_ENABLED` 并按正式入口恢复上一二进制和环境；恢复新增 Web 路由/发布目录时保留原官网与 API。迁移兼容时保留新增表和列，不删除凭证/审计数据掩盖失败，不回灌整库覆盖发布后用户新数据。需要恢复数据库时由维护者按备份与停写窗口另行操作。
