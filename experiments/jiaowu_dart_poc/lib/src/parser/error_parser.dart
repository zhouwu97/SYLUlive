import 'package:html/parser.dart' as html_parser;

/// 只从上游明确文本中判断账号密码错误，避免误把登录页变化当密码错。
abstract final class ErrorParser {
  static String? credentialErrorMessage(String body) {
    final text = html_parser.parse(body).body?.text ?? body;
    final combined = '$text $body';
    const markers = [
      '用户名或密码错误',
      '账号或密码错误',
      '账户或密码错误',
      '账号密码错误',
      '密码错误',
      '密码不正确',
      '用户不存在',
    ];
    return markers.any(combined.contains) ? '教务账号或密码错误' : null;
  }

  static String? alertMessage(String body) {
    final match = RegExp(
      r'''alert\s*\(\s*['"]([^'"]+)['"]\s*\)''',
      caseSensitive: false,
    ).firstMatch(body);
    return match?.group(1)?.trim();
  }

  static bool captchaRequired(String body) {
    final alert = alertMessage(body)?.toLowerCase() ?? '';
    final visibleText = html_parser.parse(body).body?.text ?? body;
    final combined = '$alert $visibleText $body'.toLowerCase();
    const explicitMarkers = [
      '请输入验证码',
      '请填写验证码',
      '验证码不能为空',
      '验证码错误',
      '验证码不正确',
      '验证码已过期',
      '验证码失效',
      'captcha required',
      'captcha is required',
      'invalid captcha',
      'captcha expired',
    ];
    return alert.contains('验证码') ||
        alert.contains('captcha') ||
        explicitMarkers.any(combined.contains);
  }

  static bool captchaInvalid(String body) {
    final alert = alertMessage(body)?.toLowerCase() ?? '';
    final visibleText = html_parser.parse(body).body?.text ?? body;
    final combined = '$alert $visibleText $body'.toLowerCase();
    const markers = [
      '验证码错误',
      '验证码不正确',
      '验证码校验失败',
      '验证码已过期',
      '验证码失效',
      'invalid captcha',
      'captcha expired',
    ];
    return (alert.contains('验证码') || alert.contains('captcha')) ||
        markers.any(combined.contains);
  }

  static String captchaMessage(String body) {
    return captchaInvalid(body) ? '验证码错误，请换一张后重试' : '请输入验证码';
  }
}
