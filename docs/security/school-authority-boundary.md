# School Authority Boundary

状态：PR1 安全边界与 Review 契约。当前迁移期旧路由或旧爬虫的存在是待退役债务；在
PR10b、PR11、PR12、PR13 完成前，不得写“Server Zero School Authority - Verified”。

## 权限拓扑

```text
用户设备
  ├─ AppApiClient ─────> SYLUlive Account / Community API
  ├─ SchoolPersonalClient ──> 学校个人系统（本地、用户触发）
  └─ SchoolPublicClient ─────> 学校公开资讯（无个人凭据）

Server ──X──> 学校个人系统
Server ──X──> 指令设备刷新/读取学校个人数据
Server AI ──X─> LocalSchoolProfile
```

服务端不能通过 HTTP、SSH、队列、定时任务、MCP、配置开关或“失败重试”越过上述边界。
任何新出站目的地都必须有 Host、Port、用途、Owner、到期日、健康检查和网络层策略；
只在应用代码中写 Allowlist 不算网络边界。

## 路由和能力规则

迁移期间如仍需兼容旧客户端，`/api/login_edu`、`/api/register_with_edu` 和
`/api/password/edu/reset` 及其旧别名 `/api/forgot_password` 必须独立计量、限流并带 Sunset。普通 `/api/login` 不接受或
查询 StudentID。最终切换后这些路由应返回 410，且不解析请求 Body；Go `/api/edu/*`、
`/api/personal-snapshots/erke` 和 Python 学校个人路由按计划分别退役。

新代码禁止：

```text
server/account  -> school personal runtime
server/ai       -> local academic / school device data
device_job      -> server school authority
registration    -> normal academic runtime
```

禁止新建 Server Academic Snapshot、School Device Tool、个人学校 Crawler 或 AI School
Personal Capability。需要学校数据时只能在设备本地完成，并由用户明确授权上传最小摘要。

## CI 门禁

从仓库根目录运行：

```bash
python scripts/security/school_boundary_scan.py --root . --pretty
```

扫描 JSON 至少包含：生产源码危险 TLS 命中、Python/Go 实际镜像边界、被排除探针观察、
Flutter 临时回调位置与 Owner/PR6 元数据、可选 Release Artifact 内容检查。失败命中
必须阻断合并；探针命中只有在发布边界已证明排除时才可记录为 excluded。

## Review Checklist

- [ ] Zero Credential：请求、日志、Trace、Queue、DB、Cache、Backup 无学校凭据。
- [ ] Zero Personal School Data：没有新的 Server 个人学校字段、快照或可关联派生值。
- [ ] Zero School Authority：没有服务器直连学校个人系统或远程命令设备的路径。
- [ ] Zero Hidden Fallback：没有把 Local failure 切回 Remote/Server Academic 能力。
- [ ] 生产源码无 `verify=False`、`verify = False`、`CERT_NONE`。
- [ ] 测试/探针确需弱 TLS 时，Release Artifact 明确不包含对应文件。
- [ ] Flutter 临时证书兼容策略有 Owner、原因、指纹和 PR6 删除边界。
- [ ] 路由、配置、密钥、egress、定时任务和旧客户端兼容责任已列出 Sunset。
- [ ] 已提供负向测试、发布物摘要、回滚方式、观察窗口和角色签字。

## 责任与升级

Migration Owner 负责范围和结论；Backend/Client Owner 负责实现；DBA/Data Owner 负责
数据与清理；Security Reviewer 负责四个零、TLS、凭据、egress 和负向测试；Release
Commander 负责 Gate、停止和前滚。Security Reviewer 不得独自批准自己实现的 P0 删除或
边界变更。发现疑似学校凭据或个人数据泄露时，立即停止发布并进入受控事件流程，不能
用脱敏后的猜测继续上线。
