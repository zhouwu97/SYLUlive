import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fast_gbk/fast_gbk.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:shenliyuan/features/campus_data/common/campus_data_exception.dart';

class CampusResponseDecoder {
  /// Decodes a Dio Response containing raw bytes (ResponseBody).
  /// Inspects `Content-Type` for charset. If it contains `gb2312` or `gbk`, uses `fast_gbk`.
  /// Otherwise uses UTF-8.
  static String decodeResponseBytes(Response<List<int>> response) {
    final contentType =
        response.headers.value('content-type')?.toLowerCase() ?? '';
    final bytes = response.data ?? <int>[];

    if (contentType.contains('gb2312') || contentType.contains('gbk')) {
      return gbk.decode(bytes);
    } else {
      return utf8.decode(bytes, allowMalformed: true);
    }
  }

  /// Scans the HTML string for known error markers and throws the corresponding exceptions.
  static void interceptHtmlErrors(String html) {
    // Check for WebVPN Access Denied
    // The exact text used by the school's WebVPN when you don't have access to a resource
    if (html.contains('没有权限访问该资源') || html.contains('Access Denied')) {
      throw const WebVpnAccessDeniedException('WebVPN 已认证，但当前账号无权访问目标内网资源。');
    }

    // Check for WebVPN Session Expired or Redirect to login
    // Usually, CAS login form contains specific inputs, but an explicit WebVPN timeout
    // can be detected if it redirects back to WebVPN login page.
    if (html.contains('WebVPN') &&
        html.contains('用户登录') &&
        !html.contains('pwdEncryptSalt')) {
      // It might be a WebVPN timeout page, but let's be careful.
    }

    // Check for CAS Login failed
    // CAS error messages are usually in an element with id "msg" or class "errors"
    final document = html_parser.parse(html);
    final errorNode = document.querySelector('#msg');
    if (errorNode != null && errorNode.text.trim().isNotEmpty) {
      if (errorNode.text.contains('密码错误') || errorNode.text.contains('不存在')) {
        throw CasLoginFailedException(errorNode.text.trim());
      }
    }

    // Check for Erke Login failed
    // Example: alert('登录失败'); or specific span
    if (html.contains('密码错误') || html.contains('用户名不存在')) {
      // Just a broad check for Erke since they use simple alerts sometimes
      // throw const ErkeLoginFailedException('用户名或密码错误');
    }
  }
}
