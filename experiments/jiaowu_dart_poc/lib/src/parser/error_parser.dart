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
    final lower = body.toLowerCase();
    return body.contains('验证码') ||
        lower.contains('captcha') ||
        lower.contains('kaptcha');
  }
}
