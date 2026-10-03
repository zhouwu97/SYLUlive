# 2026-10-03 服务器维护与教务配置同步核对

## 范围和基准

- 用户明确授权修复临时上传清理权限、退役旧 `/edu-api/`，核对新版教务绑定链路。
- 目标：101.36.125.129；Go 运行 SHA：`0ec30b43026dc5eb71b1e97eb2e0eaa4123f86a7`。
- 本地审核 SHA：`5e731dd6f94b2b7ee704d043ed6d8bc34438f138`。
- 风险：生产 Nginx 配置与文件权限维护按 R3；绑定链路只读审核。
- 保留原有未跟踪目录 `client/release-artifacts/1.7.5-1709-candidate/`，未推送、未更换二进制、未改变教务退役开关。

## 已执行维护

### 临时上传清理

原 `.trash` 为 root:root 755，服务用户 shenliyuan 无法创建 `upload-janitor`；24 小时内同两条记录共出现 54 次权限错误。

仅创建 `/opt/shenliyuan/uploads/.trash/upload-janitor`，属主为 shenliyuan:shenliyuan，权限 750。父目录及其他上传目录保持原状。以服务用户执行可写检查通过。

重启现有 shenliyuan 服务使启动期 janitor 执行：`scanned=2 marked=0 removed=2 removed_bytes=1024 retained_referenced=0 retained_recent_grant=0 errors=0`。两条原 deleting 记录已不在 files 表。未手工删文件或修改数据库记录。

### 旧教务代理退役

配置：`/etc/nginx/conf.d/sylulive.conf`。将旧 18000 代理替换为 `/edu-api` 精确匹配及 `/edu-api/` 前缀匹配的 410 JSON 响应，错误码 `LEGACY_EDU_PROXY_RETIRED`。

备份：`/opt/shenliyuan-backups/ops-20261003-092928/nginx.conf.before`，同目录 `change.json` 记录修改目标。`nginx -t` 通过后 reload。首次 reload 后立即请求仍命中旧 worker 的 301/502，稍后复查两个入口均为 410，最终复查仍为 410。

回退：将该备份恢复到原配置路径，执行 `nginx -t` 成功后 reload Nginx。隔离子目录正常留用；若确需撤销目录创建，只能在确认无正在运行的清理任务、目录为空后删除该子目录，不操作父目录或上传业务文件。

## 新版教务同步结论

新版在设备直接完成学校登录。登录成功后将账号目标与 outbox 一次落盘，立即异步对账 `/api/academic-account-configs`；服务器将 App user、provider、student_id、revision 和状态持久化于 academic_account_configs，不接收学校密码/Cookie。同一 App 账号的配置对账每 30 秒尝试一次，并在启动及课表读取成功后补投递。定时器依赖应用进程运行，后台暂停、断网或服务故障时不承诺严格 30 秒送达。

`POST /api/student-identity/bind` 只接收本机声明并返回 verified=false，不持久化 AcademicIdentityBinding，不授予可信学生身份权限。实际持久化的账号配置与服务器核验身份必须区分。

当前只退役 Nginx `/edu-api/`；没有打开 SCHOOL_AUTHORITY_RETIRED。当前全局 retirement gate 在该开关为 true 时会阻断 `/student-identity/bind`，因此不能将本次旧代理退役扩大成所有个人教务路由退役。

线上证据（仅聚合，无个人学号或凭据）：

- 24 小时内 `/api/student-identity/bind` 成功 POST 193 次，账号配置 GET 成功 716 次。
- 配置表有本科 active 416 行、研究生 active 2 行；本科 deleted 2 行、研究生 deleted 1 行。
- 最近配置写入及 receipt 时间为 2026-10-01 20:46:37 +08；24 小时日志中未发现配置 PUT 成功请求。因此声明请求成功本身不能证明同次配置已写入。
- 当前 Android stable 最新 published 为 1.7.5 / 1708，发布时间 2026-09-20；1709 只有本地候选目录，未在服务器发布表中出现。
- 最新课表补投递代码已实现，但尚不能认为已交付线上用户。需完成 1709 真机验收、正式客户端发布，并验证真实登录后的配置 PUT 和数据库更新。

## 验证与限制

- Flutter 定向测试：academic_local_connection、local_academic_account_store、academic_identity_client、academic_server_access_guard 共 68 项通过；academic_identity_projection 16 项通过。覆盖登录成功、拒绝密码、断网重试、重启补投递、账号隔离、配置幂等与旧代理访问阻断。
- Go 定向测试首次因 Windows MinGW 链接失败；切换到已安装的 MSYS GCC 后仍在 cgo 构建失败。未修改测试或断言，Go 测试标记为未完成。
- Nginx 配置校验通过；退役入口最终 410；HTTPS `/api/version` 200 且 SHA 不变；身份与配置接口未登录访问 401。
- Go `/health` 为 ok，运行 SHA 不变；shenliyuan、Nginx、教务和 RAG 服务均 active。
- 未使用真实学校账号完成登录和配置写入；未伪造生产 JWT、未写入生产测试身份。不能据此宣称完整真实绑定业务已验收。
- 本次不是新版本发布，无新二进制或 CI 发布放行结论。
