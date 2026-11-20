# 沈理校园用户协议维护入口

当前正文统一维护在 [`client/lib/legal/legal_documents.dart`](../../client/lib/legal/legal_documents.dart)，App 与公开页面共用同一份内容。此处不再维护独立政策草稿。

公开入口为 `/terms`；公开 HTML 由 `client/tool/export_legal_documents.dart` 导出并嵌入 Go 二进制。修改正文须同步 App 与服务端确认版本，历史同意记录保留。网关、验证和回退统一见[公开法律文档运维](../ops/public-legal-documents.md)。
