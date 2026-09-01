import 'package:html/parser.dart' as html_parser;

/// 识别“HTTP 200 但实际是登录页”的情况。
abstract final class LoginPageDetector {
  static bool isLoginPage(String body) {
    if (body.trim().isEmpty) return false;

    final document = html_parser.parse(body);
    final hasLoginForm = document.querySelectorAll('form').any((form) {
      final action = (form.attributes['action'] ?? '').toLowerCase();
      final hasUsername = form.querySelector('[name="yhm"]') != null;
      final hasPassword = form.querySelector('[name="mm"]') != null;
      return action.contains('login_slogin') || (hasUsername && hasPassword);
    });
    if (hasLoginForm) return true;

    final lowerBody = body.toLowerCase();
    return lowerBody.contains('login_slogin') ||
        body.contains('统一身份认证') ||
        body.contains('用户登录');
  }
}
