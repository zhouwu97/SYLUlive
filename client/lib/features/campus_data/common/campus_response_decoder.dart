import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fast_gbk/fast_gbk.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:shenliyuan/features/campus_data/common/campus_data_exception.dart';

enum CampusResponseContext {
  requestingCasLoginPage,
  accessingProtectedResource,
}

class CampusResponseDecoder {
  /// Decodes a Dio Response containing raw bytes (ResponseBody).
  /// Inspects `Content-Type` for charset. If it contains `gb2312` or `gbk`, uses `fast_gbk`.
  /// Otherwise uses UTF-8.
  static String decodeResponseBytes(Response<List<int>> response) {
    final contentType =
        response.headers.value('content-type')?.toLowerCase() ?? '';
    final bytes = response.data ?? <int>[];

    final match = RegExp(r'charset\s*=\s*([-\w]+)', caseSensitive: false).firstMatch(contentType);
    final charset = match?.group(1);

    if (charset == null || charset.isEmpty || charset == 'iso-8859-1' || charset == 'latin-1') {
      try {
        return utf8.decode(bytes);
      } catch (_) {
        try {
          return gbk.decode(bytes);
        } catch (_) {
          return utf8.decode(bytes, allowMalformed: true);
        }
      }
    }

    try {
      if (charset == 'utf-8') {
        return utf8.decode(bytes);
      } else if (charset.contains('gb')) {
        return gbk.decode(bytes);
      }
      return utf8.decode(bytes);
    } catch (_) {
      try {
        return gbk.decode(bytes);
      } catch (_) {
        return utf8.decode(bytes, allowMalformed: true);
      }
    }
  }

  /// Scans the HTML string for known error markers and throws the corresponding exceptions.
  static void interceptHtmlErrors(String html, {required Uri realUri, CampusResponseContext context = CampusResponseContext.accessingProtectedResource}) {
    if (html.contains('The website you are visiting is protected by WebVPN')) {
      throw const WebVpnSessionExpiredException('WebVPN 访问被拒绝，可能处于未登录状态');
    }
    
    if (context == CampusResponseContext.accessingProtectedResource && realUri.path.toLowerCase().endsWith('/login') && html.contains('pwdEncryptSalt')) {
      throw const WebVpnSessionExpiredException('统一认证登录会话失效或被重定向至登录页');
    }

    // Check for WebVPN Access Denied
    if (html.contains('没有权限访问该资源') || html.contains('Access Denied')) {
      throw const WebVpnAccessDeniedException('WebVPN 已认证，但当前账号无权访问目标内网资源。');
    }

    if (context == CampusResponseContext.accessingProtectedResource && html.contains('WebVPN') && html.contains('pwdEncryptSalt') && html.contains('casLoginForm')) {
      throw const WebVpnSessionExpiredException('WebVPN Session 已过期或无效');
    }

    // Check for CAS Login failed
    final document = html_parser.parse(html);
    final errorNode = document.querySelector('#msg');
    if (errorNode != null && errorNode.text.trim().isNotEmpty) {
      if (errorNode.text.contains('密码错误') || errorNode.text.contains('不存在')) {
        throw CasLoginFailedException(errorNode.text.trim());
      }
    }

    // Check for Erke errors
    final layerAlertMatch = RegExp(r"""layer\.alert\(\s*['"]([^'"]+)['"]""").firstMatch(html);
    if (layerAlertMatch != null) {
      final msg = layerAlertMatch.group(1)!;
      if (msg.contains('密码错误') || msg.contains('不存在')) {
        throw ErkeLoginFailedException(msg);
      }
    }
    
    final alertMatch = RegExp(r"""alert\(\s*['"]([^'"]+)['"]\s*\)""").firstMatch(html);
    if (alertMatch != null) {
      final msg = alertMatch.group(1)!;
      if (msg.contains('密码错误') || msg.contains('不存在')) {
        throw ErkeLoginFailedException(msg);
      }
    }
  }
}
