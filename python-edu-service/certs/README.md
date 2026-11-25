# 本科学校证书链

学校 HTTPS 端点只发送网站叶证书。`sylu-academic-chain.pem` 提供公开中间链；Dart 客户端在 `JiaowuTrustChain` 中内置同一组 PEM。学校证书轮换后，两端同步更新。

| 证书 | 签发者 | AIA 来源 | DER SHA-256 | 有效期（UTC） |
| --- | --- | --- | --- | --- |
| TrustAsia OV TLS RSA CA 2024 | TrustAsia TLS RSA Root CA | `http://ica.wt.trustasia.com/TrustAsiaOVTLSRSACA2024.crt` | `d0b626c8ad93962296b3920106ed7fb3818fcb98e0b73e799141b42521335b0f` | 2024-05-15 至 2034-05-15 |
| TrustAsia TLS RSA Root CA（交叉签名） | Certum Trusted Network CA | `http://ica.wt.trustasia.com/TrustAsiaTLSRSARootCA.crt` | `ce0df856ea6cc0ebe068f55c4cc4de77def45cacb2d4e946d8ade706666f5887` | 2025-10-07 至 2029-01-14 |

链路为学校叶证书 → TrustAsia OV TLS RSA CA 2024 → TrustAsia TLS RSA Root CA（交叉签名）→ 系统信任的 Certum Trusted Network CA。包内不加入自签名根证书，也不固定短期的网站叶证书。

部署检查使用系统 CA 根证书库，将 PEM 作为 untrusted 中间链验证学校证书及 `jxw.sylu.edu.cn` 域名。Python 关闭 partial-chain 信任，继续要求系统可信根。证书更新时重新核对 AIA 来源、签名链、指纹、有效期和域名，并执行 Dart 协议回归、Python TLS 测试与 Android 清数据后的首次 CSRF 请求。
