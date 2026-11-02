# 本科学校证书链

学校 HTTPS 端点只发送网站叶证书。随服务提供公开中间证书，使客户端可以构建完整验证链。

- 来源为叶证书 Authority Information Access 指定的 `http://cacerts.digicert.cn/TrustAsiaTLSProRSACA2025.crt`。
- Subject 为 TrustAsia TLS Pro RSA CA 2025。
- Issuer 为 DigiCert Global Root G2。
- DER SHA-256 为 `416a2c89515b8bc14e13677024e2a82e8b1b2f4117a88fd11b8bbd25d1a5c517`。
- 有效期为 2025-01-08 至 2035-01-07。

部署检查使用系统 CA 根证书库，将本文件作为 untrusted 中间链验证学校证书及 `jxw.sylu.edu.cn` 域名。代码关闭 partial-chain 信任，继续要求系统可信根。证书更新时重新核对来源、签名链、指纹、有效期和域名。
