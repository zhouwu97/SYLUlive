import 'package:test/test.dart';

import '../../lib/src/parser/error_parser.dart';

void main() {
  test('普通登录页包含 captcha 资源时不误判为验证码挑战', () {
    expect(
      ErrorParser.captchaRequired('''
        <form action="login_slogin.html">
          <input name="yhm"><input name="mm">
          <script src="/static/captcha.js"></script>
        </form>
      '''),
      isFalse,
    );
  });

  test('登录响应明确提示请输入验证码时识别为挑战', () {
    const body = '<script>alert("请输入验证码");</script>';

    expect(
      ErrorParser.captchaRequired(body),
      isTrue,
    );
    expect(ErrorParser.captchaInvalid(body), isFalse);
    expect(ErrorParser.captchaMessage(body), '请输入验证码');
  });

  test('验证码错误和过期提示仍属于可续登挑战', () {
    const invalidBody = '<div class="error">验证码错误</div>';

    expect(
      ErrorParser.captchaRequired(invalidBody),
      isTrue,
    );
    expect(ErrorParser.captchaInvalid(invalidBody), isTrue);
    expect(ErrorParser.captchaMessage(invalidBody), '验证码错误，请换一张后重试');
    expect(
      ErrorParser.captchaRequired('<div class="error">验证码已过期</div>'),
      isTrue,
    );
    expect(
      ErrorParser.captchaRequired(
        '<script>alert("验证码校验失败");</script>',
      ),
      isTrue,
    );
  });
}
