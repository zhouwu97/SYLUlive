# 沈理校园教务助手

Manifest V3 扩展，为沈理校园 Web 提供本机学校查询、连接、备份和课表提醒。消息协议和数据边界以 `packages/academic-contracts`、[Web README](../web/README.md) 为准。学校密码不得进入网页消息桥、日志或安装包。

## 构建与验证

```powershell
pnpm --filter @sylulive/extension check
pnpm test
pnpm --filter @sylulive/extension build
pnpm --filter @sylulive/extension dev
pnpm --filter @sylulive/extension package:store
pnpm exec playwright test web/e2e/extension-store.spec.ts web/e2e/extension-reenable.spec.ts
```

`dist/` 为生产站点手动安装包，`dist-dev/` 另含本机 5173 站点；`dist-store/` 是商店专用构建，`release-store/` 含 ZIP 和 SHA-256 清单。商店包只包含生产 HTTPS 站点和三个可选 HTTPS 学校域名，不包含 HTTP 体测或 cookies 权限。学校身份仍在每次读取前后核验；本科和二课请求不再额外枚举浏览器标签页，研究生保留 ASP 会话前缀查找。

图标源为 `assets/icon.svg`，随包提供 16、32、48、128 像素 PNG。ZIP 根目录直接包含 manifest，文件列表固定、排序和时间戳固定。发布材料与账号步骤见 [store/README.md](store/README.md)，隐私正文唯一来源为 [store/privacy.txt](store/privacy.txt)，公共 HTML 由 `client/tool/export_legal_documents.dart` 生成。
