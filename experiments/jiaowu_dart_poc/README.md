# jiaowu_dart_poc

SYLUlive 教务客户端的独立纯 Dart 协议实验包。它与 `client/` 和现有
`python-edu-service/` 解耦，用 Python crawler 作为协议基准，先验证：

```text
HTTP + CookieJar → CSRF → RSA PKCS#1 v1.5 → 登录探活 → 学生信息
```

当前版本只实现第一批 P0/P1 链路，暂不包含课表、成绩、自动重登、验证码图片、
考试、真机 Flutter Probe。这样可以先把登录边界稳定下来，再逐步扩展协议。

## 安全边界

- `verify` 由 Dart IO 的默认 TLS 校验负责，不关闭证书校验。
- Dio 关闭自动重定向，保留 302/901 给分类器判断。
- 所有请求共享同一个 `CookieJar`，不在业务请求中手动拼接 Cookie。
- 日志与 Probe 只输出 Cookie 名称，不输出 Cookie 值、密码、CSRF 或完整页面。
- 真实账号只允许本地手动 Probe，禁止放入 fixture、源码或 CI。

## 运行测试

在仓库根目录执行：

```bash
cd experiments/jiaowu_dart_poc
dart pub get
dart analyze
dart test
```

## 本地 Live Probe

推荐通过环境变量传入凭据，避免密码出现在命令行历史中：

```powershell
$env:JIAOWU_STUDENT_ID = '你的学号'
$env:JIAOWU_PASSWORD = '你的密码'
dart run bin/jiaowu_probe.dart --action all
```

也支持 `--student-id`、`--password`，但不建议在共享终端使用。Probe 默认只执行
登录和学生信息；`--action login` 只验证登录，不再次获取学生信息。

## 当前协议合同

| 项目 | 合同 |
| --- | --- |
| Base URL | `https://jxw.sylu.edu.cn` |
| 重定向 | 不自动跟随 |
| 登录页 | `GET /xtgl/login_slogin.html` |
| CSRF | `#csrftoken` 的 `value`，逗号时取第一段 |
| 公钥 | `GET /xtgl/login_getPublicKey.html?time=...&_ =...`（实际参数名为 `_`） |
| 密码 | UTF-8 + RSA PKCS#1 v1.5 + Base64 |
| 登录 | `POST /xtgl/login_slogin.html?time=...`，保留 `language/yhm/mm/csrftoken` |
| 登录探活 | 学生信息页优先，菜单页回退 |
| 学生信息 | `GET /xsxxxggl/xsgrxxwh_cxXsgrxx.html`，`gnmkdm=N100801` |
| 会话失效 | 901、302 到登录页、200 登录 HTML |

公钥的 `_` 参数在 README 中用空格展示仅为避免视觉误读，代码使用精确的 `_`。

## 后续 Gate

1. P0：`dart analyze`、fixture 测试、RSA 私钥解密测试、登录探活。
2. P1：课表 Desktop/Mobile fallback、RawCourse、周次解析、成绩预热与分页。
3. P1：Python ↔ Dart canonical JSON 差分。
4. P2：最小 Flutter Android 真机 Probe。
5. 全部通过后，才通过 path dependency 接入主 App。
