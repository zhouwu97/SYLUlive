import 'package:html/parser.dart' as html_parser;

import '../error/jiaowu_exception.dart';

/// 从登录页提取 CSRF。优先按 DOM 读取，兼容属性顺序和单/双引号。
abstract final class CsrfParser {
  static String parse(String body) {
    final document = html_parser.parse(body);
    final tokenElement = document.querySelector('#csrftoken');
    final rawToken = tokenElement?.attributes['value']?.trim();
    if (rawToken == null || rawToken.isEmpty) {
      throw const LoginPageChangedException(
        message: '学校登录页面缺少 CSRF 参数，请稍后重试或联系管理员',
      );
    }

    final token = rawToken.split(',').first.trim();
    if (token.isEmpty) {
      throw const LoginPageChangedException(
        message: '学校登录页面的 CSRF 参数为空，请稍后重试或联系管理员',
      );
    }
    return token;
  }
}
