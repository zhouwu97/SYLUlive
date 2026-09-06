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

    // 文本/标题只是辅助证据，必须与表单同时存在，避免普通页面脚本或
    // 帮助文案中出现 login_slogin 时误判会话失效。
    final auxiliaryText = <String>[
      document.querySelector('title')?.text ?? '',
      document.body?.text ?? '',
    ].join(' ');
    final hasAuxiliaryMarker =
        auxiliaryText.contains('统一身份认证') || auxiliaryText.contains('用户登录');
    return hasAuxiliaryMarker && document.querySelector('form') != null;
  }
}
