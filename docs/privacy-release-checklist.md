# 隐私功能发布清单

本项目的法律文档在 Flutter 客户端中展示。个人信息请求统一由应用内“隐私与数据权利”入口受理与跟踪。

```powershell
flutter build apk --release `
  --dart-define=APP_API_URL=https://sylulive.online/api
```

发布前确认：

- 用户协议、隐私政策、社区规则、未成年人保护规则、投诉举报规则、第三方服务说明和教务数据专项授权均已完成法务核验；
- 每次修改法律文档时，同时递增客户端 `LegalDocuments.version` 与服务端 `models.LegalDocumentVersion`；
- 管理员已具备 `/api/admin/privacy/requests` 的处理权限和处理时限；
- 教务独立服务可正常响应解绑请求，避免账号注销后遗留认证凭证。
