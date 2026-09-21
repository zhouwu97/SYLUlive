# 回滚与发布验收

## 回滚顺序

1. 停止继续流量切换，保留当前日志和安全事件。
2. 将 Go 二进制切回上一稳定版本或执行部署脚本的上一 SHA。
3. 仅在迁移兼容时回滚数据库；不可逆迁移必须提前准备向前兼容方案。
4. 恢复 systemd / Compose 服务并检查 health、version、数据库连接和 Nginx。
5. 验证登录、验证码、上传、反馈、安全中心和关键公共接口。

~~~bash
systemctl restart shenliyuan
systemctl is-active shenliyuan
curl -fsS http://127.0.0.1:8080/health
curl -fsS http://127.0.0.1:8080/version
~~~

## 发布验收

- /health 正常，/version 的 git_sha 与目标一致。
- 127.0.0.1:8080 正常监听，公网不能绕过 Nginx 访问 Go。
- 两个公网出口的来源指纹不同，伪造 X-Forwarded-For 不改变来源。
- 验证码实际可发送、可校验，SMTP QUIT 网络抖动不会删除已提交 challenge。
- 安全中心能看到真实攻击事件和来源指纹。
