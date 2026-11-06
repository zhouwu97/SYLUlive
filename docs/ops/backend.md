# Go 后端部署

## 目录与进程

- 源码：/opt/shenliyuan-src
- 运行目录：/opt/shenliyuan
- systemd：shenliyuan.service
- 二进制：/opt/shenliyuan/shenliyuan
- 本机监听：127.0.0.1:8080 或容器内部 0.0.0.0:8080

生产更新使用 deploy/deploy-shenliyuan，并传入分支或不可变 SHA：

~~~bash
/opt/shenliyuan-src/deploy/deploy-shenliyuan <完整 commit SHA>
~~~

发布前确保 .env 已配置 JWT_SECRET、DSN、TRUSTED_PROXY_CIDRS、SECURITY_EVENT_HMAC_SECRET、SECURITY_SOURCE_ATTRIBUTION_VALID_FROM 以及 Compose 强制要求的上传和法律合规开关。

## 检查

~~~bash
systemctl is-active shenliyuan
curl -fsS http://127.0.0.1:8080/health
curl -fsS http://127.0.0.1:8080/version
journalctl -u shenliyuan -n 100 --no-pager
~~~

公网不应直接访问 Go 8080；Nginx 的 limit_req、limit_conn 和来源代理配置必须生效。

## 获赞兼容快照校准

新版资料和点赞明细统一读取当前有效点赞事实，详见 [API](../../server/API.md#6-消息与通知-messages)。普通读取不会修改历史数值。兼容列继续接受旧增量写入，不能用于有效获赞排行榜或独立统计；校准仅生成当前快照，不使该列成为持续准确的计数器。更新服务端后刷新资料即可显示正确值，不依赖先执行校准。

启动时的 AutoMigrate 为 `likes(target_type,target_id)` 增加普通索引 `idx_like_target`，不删除原唯一索引或任何点赞记录。大表创建索引需要发布窗口，并观察锁等待和磁盘空间；按正式发布入口执行，不在运行期间绕过发布流程改表。

`server/cmd/backfill_total_likes_received` 默认只预览差异，不再读取应用配置、普通 `DSN` 或 `/opt/shenliyuan/.env`。在已核验的专用环境变量 `RECEIVED_LIKES_BACKFILL_DSN` 中设置目标连接后，从已审核版本的 `server/` 目录执行：

~~~bash
go run ./cmd/backfill_total_likes_received
~~~

输出 JSON 包含 `applied/users/changed/changes`，每项差异为 `user_id/before/after`。预览使用一致性读事务，不写数据；没有剩余有效点赞的用户也会列出归零差异。确认连接目标、备份与差异后，依照数据操作授权在停止所有相关写入的维护窗口显式执行：

~~~bash
go run ./cmd/backfill_total_likes_received -apply -timeout 5m
~~~

写入在单个事务内重算并更新，PostgreSQL 会锁定 `users/posts/replies/likes`，防止跨批次漂移和覆盖并发增量；锁等待也受超时控制。失败整批回滚，重复执行不会重复扣减，不改变用户更新时间，也不删除点赞事实。默认 PostgreSQL；隔离 SQLite 验证可加 `-driver sqlite`，更换变量名可用 `-dsn-env NAME`。不要将连接字符串直接放入命令行或报告。

恢复时优先回退服务端代码；新索引对旧版本兼容，可以保留。旧版仍可能显示旧口径，因此回退代码不承诺继续维持新版有效获赞语义。若业务要求撤回已批准的批量快照写入，应在停写窗口按备份恢复指定列，禁止撤销实际点赞或内容状态来凑回旧总数。
