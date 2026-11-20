# 公开法律文档

扩展专属隐私说明另以 `browser-extension/store/privacy.txt` 为正文来源，确认版本独立于 App 的基础协议；同一导出工具生成 `extension-privacy.html`，公开路由为 `/extension/privacy`。联系信息仍由 `AppContacts` 生成，不复制另一套邮箱。商店包、后台披露与截图说明见 `browser-extension/store/README.md`。

App 与公开法律页面的正文维护入口是 `client/lib/legal/legal_documents.dart`。`docs/legal/` 只保留维护入口说明，不再维护另一套政策草稿。公开 HTML 位于 `server/static/legal/`，由工具生成并由 Go `embed` 编入二进制；更新文件需要重建服务端，修改运行目录下的文件不会替换已嵌入的版本。

## 修改与检查

正文或告知范围变化时，核实当前处理活动和公开事实，并将 App `LegalDocuments.version` 与 Go `models.LegalDocumentVersion` 同步递增。开发者名称和联系邮箱统一维护在 `client/lib/config/app_contacts.dart`，由 App 的“关于 → 联系作者”和法律文档共用；这些内容来自 App 已公开资料，不再分别复制。新增或变更身份事实时仍须有维护者提供的依据。

在仓库根执行：

```powershell
dart run client/tool/export_legal_documents.dart
dart run client/tool/export_legal_documents.dart --check
```

CI 的客户端 job 执行导出一致性检查；Go 的 `TestLegalDocumentsEmbeddedAndPublic` 检查公开正文、确认版本、GET/HEAD 及不存在路径。`/privacy#edu-data-consent` 是教务专项授权的独立章节，内容来自同一个 App 文档源。历史确认记录不批量重写；旧版本按现有门禁进入重新确认。Web 在读取页和表单保留确认入口，教务专项授权单独勾选，确认成功后由用户重新提交原写操作。

## 网关接入

`/terms`、`/privacy`、`/extension/privacy` 必须路由到 Go，不能落入官网或 Flutter 首页兜底：

- Docker 使用 `nginx/docker.conf` 中的法律 location。
- 官网 systemd 部署将 `nginx/sylulive-site-v5-deep-links.conf` 中对应 location 合并到实际 HTTPS server。
- `web/deploy/nginx.conf` 提供同样的 systemd location；与官网片段一起合并时只保留一份。
- 开发服务器按 `SYLULIVE_API_ORIGIN` 代理上述三个路径，默认本地 Go。注册和重新确认的链接使用当前 origin。

生产配置与服务端必须按 DEPLOY.md 的固定候选、备份、验证和回滚流程发布。对候选完整配置先执行 `nginx -t`；确认上游不将协议请求重定向回首页。发布后分别访问上述三个公网 URL，检查 HTTP 状态、Content-Type、正文标题和确认版本；仅检查 HTTP 200 不足以判定成功。

可在本地使用已准备的 Nginx 可执行文件验证三个配置片段的法律路由：

```powershell
python scripts/verify_legal_gateway.py --nginx C:/path/to/nginx.exe
```

工具只创建临时目录、临时 HTTP 上游和随机回环端口，结束关闭自己的进程；它验证真实 Nginx 中的法律 location，不代替生产完整配置、TLS 或 Linux 静态文件加速验收。

## 回退

保留原网关配置备份及上一个服务端二进制；按正式入口回退，并再次检查正文标题和版本。确认版本变更后生成的新旧记录都保留，不能通过改写同意时间或批量替换历史版本消除重新确认状态。不得用重新指向首页作为协议页面的降级方案。
