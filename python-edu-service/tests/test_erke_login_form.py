"""二课登录表单不得同时提交明文密码。

页面已经用 pubKey 把密码 RSA 加密后放进 pwd 字段提交（见 SyluCrawler 的类
文档"密码 RSA 加密规则"）。此前又额外提交了一份明文 Password，加密形同虚设，
明文还会进入上游与中间设备的表单日志。
"""

from urllib.parse import parse_qs

from erke_crawler import SyluCrawler

PLAINTEXT_PASSWORD = "Secret#2026"

LOGIN_HTML = """
<html><body>
  <form>
    <input id="__VIEWSTATE" value="vs-value" />
    <input id="__VIEWSTATEGENERATOR" value="vsgen-value" />
    <input id="__EVENTVALIDATION" value="ev-value" />
    <input id="pubKey" value="pub-key-value" />
    <span id="code-box">K777</span>
  </form>
</body></html>
"""


class _FakeResponse:
    def __init__(self, text, status_code=200):
        self.text = text
        self.status_code = status_code
        self.encoding = "utf-8"

    @property
    def cookies(self):
        class _Cookies:
            def get_dict(self):
                return {}

        return _Cookies()


class _FakeSession:
    def __init__(self):
        self.posted_bodies = []

    def get(self, *args, **kwargs):
        return _FakeResponse(LOGIN_HTML)

    def post(self, url, data=None, **kwargs):
        self.posted_bodies.append(data)
        return _FakeResponse("<html>登录失败</html>")


def _login_with_fake_session():
    crawler = SyluCrawler.__new__(SyluCrawler)
    crawler.session = _FakeSession()
    # 跳过 __init__（会创建真实 requests.Session 并加载 ddddocr 模型），
    # 只补齐 login() 用到的属性。
    crawler._encrypted_host = "encrypted-host"
    crawler.rsa_encrypt = lambda password, pub_key: "ENCRYPTED-PWD"
    result = crawler.login("2026000101", PLAINTEXT_PASSWORD)
    return crawler.session, result


def test_login_form_never_carries_the_plaintext_password():
    session, _ = _login_with_fake_session()

    assert len(session.posted_bodies) == 1
    body = session.posted_bodies[0]
    assert PLAINTEXT_PASSWORD not in body


def test_login_form_still_sends_encrypted_password():
    session, _ = _login_with_fake_session()

    # parse_qs 默认丢弃空值字段，这里必须保留才能断言 Password 被清空。
    parsed = parse_qs(session.posted_bodies[0], keep_blank_values=True)
    assert parsed["pwd"] == ["ENCRYPTED-PWD"]
    assert parsed["UserName"] == ["2026000101"]
    # 字段本身保留，只是空串。
    assert parsed["Password"] == [""]
