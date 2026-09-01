# jiaowu_mobile_probe

SYLU 教务系统 Android transport 探针。它通过 path dependency 使用
`../jiaowu_dart_poc`，用于验证真实设备上的 DNS、TCP/TLS、登录页和 CSRF，
不替代主 App，也不修改教务协议实现。

## 运行

```bash
flutter pub get
flutter run
```

进入页面后可以先点击“网络诊断”，无需填写账号。诊断顺序为：

```text
DNS → HTTPS GET /xtgl/login_slogin.html → CSRF 解析
```

页面只展示 IPv4/IPv6 数量、HTTP 状态和安全 transport 摘要，不展示 Cookie、
请求体、响应体或密码。

TLS 握手失败时，摘要只会显示白名单原因，例如 `UNKNOWN_CA`、
`HOSTNAME_MISMATCH`、`CERT_EXPIRED`、`CERT_NOT_YET_VALID`、
`TLS_PROTOCOL_VERSION` 或 `TLS_HANDSHAKE_GENERIC`，不会显示底层异常原文。

## Android A/B

Debug 构建提供两个按钮：

- “网络诊断”：使用 Android 系统证书信任链。
- “Debug insecure TLS”：仅允许 Debug，且只对 `jxw.sylu.edu.cn` 放宽证书校验。

后者只用于判断是否存在证书链兼容问题，绝不能用于正式包。Release 代码路径
不会创建 trust-all HTTP 客户端；正式修复应优先修复学校证书链，其次采用明确的
CA 或公钥 pinning 方案。

建议在同一台设备上依次测试 5G 和与电脑相同的 Wi-Fi，并记录两种 TLS 模式的
诊断摘要。探针的 Android 主 Manifest 已声明 `INTERNET` 和
`ACCESS_NETWORK_STATE`，因此 Release 包也具备联网权限。

## 验证

```bash
dart test ../jiaowu_dart_poc
flutter analyze
flutter test
flutter build apk --release
```

真实设备验证仍需手工覆盖 5G/Wi-Fi、前后台切换、锁屏解锁，以及登录后的
Profile、课表和成绩请求。
