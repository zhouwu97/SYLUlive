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
