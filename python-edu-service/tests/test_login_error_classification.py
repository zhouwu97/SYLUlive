from services.crawler import EduCrawler, LoginFailedError


def test_credential_error_message_requires_explicit_password_text():
    crawler = EduCrawler()

    assert crawler._credential_error_message("用户名或密码错误") == "教务账号或密码错误"
    assert crawler._credential_error_message("<html><title>统一认证</title></html>") is None


def test_login_failed_error_carries_code():
    err = LoginFailedError("学校登录状态未知，请稍后重试或联系管理员", "UNKNOWN_LOGIN_STATE")

    assert str(err) == "学校登录状态未知，请稍后重试或联系管理员"
    assert err.code == "UNKNOWN_LOGIN_STATE"
