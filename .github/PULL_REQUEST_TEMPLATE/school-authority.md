## School Authority Review

本模板用于涉及账号、教务、二课、校园准入、网络请求、AI 工具或发布物的变更。请附
实际 Base Branch、Base SHA、证据生成时间和回滚负责人；不要在 PR 中粘贴 Email、StudentID、
Cookie、Token、学校密码或可回溯的生产明细。

### 四个零

- [ ] Zero Credential：Server/API/日志/Trace/Queue/DB/Cache/Backup 不接收或保存学校凭据。
- [ ] Zero Personal School Data：没有新增可关联个人的 StudentID、课表、成绩、考试、学分、二课或派生值。
- [ ] Zero School Authority：Server 不直连学校个人系统，也不远程命令设备读取学校数据。
- [ ] Zero Hidden Fallback：Local failure 不会切回 RemoteAcademicGateway、Server Academic 或 School Device Tool。

### 安全门禁

- [ ] 已运行 `python scripts/security/school_boundary_scan.py --root . --pretty`，并附 JSON 原始结果。
- [ ] 生产源码无 `verify=False`、`verify = False`、`CERT_NONE`。
- [ ] 测试/探针如含弱 TLS 模拟，已由 Release Artifact 或 Docker 边界证明不进入生产。
- [ ] Flutter 临时证书兼容策略有 Owner、原因、指纹和 PR6 删除边界。
- [ ] 新出站目的地具备 Host/Port/用途/Owner/到期日和网络层策略。

### 证据与回滚

- BaseBranch / BaseSHA：
- SchemaSnapshotAt / ProductionConfigSnapshotAt：
- 测试命令及原始结果：
- 发布物摘要或镜像边界证据：
- 灰度指标与观察窗口：
- 停止、回退和前滚负责人：
- Migration / Backend / Client / DBA / Security / Release 角色：
