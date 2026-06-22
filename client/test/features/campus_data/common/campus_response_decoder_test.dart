import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/campus_data/common/campus_data_exception.dart';
import 'package:shenliyuan/features/campus_data/common/campus_response_decoder.dart';

void main() {
  group('CampusResponseDecoder', () {
    test('decodes GBK when Content-Type specifies gb2312 or gbk', () {
      // "测试" in GBK: B2 E2 CA D4
      final bytes = [0xB2, 0xE2, 0xCA, 0xD4];
      final response = Response<List<int>>(
        requestOptions: RequestOptions(path: ''),
        data: bytes,
        headers: Headers.fromMap({
          'content-type': ['text/html; charset=gb2312']
        }),
      );

      final decoded = CampusResponseDecoder.decodeResponseBytes(response);
      expect(decoded, '测试');
    });

    test('decodes UTF-8 when no charset specified', () {
      // "测试" in UTF-8: E6 B5 8B E8 AF 95
      final bytes = [0xE6, 0xB5, 0x8B, 0xE8, 0xAF, 0x95];
      final response = Response<List<int>>(
        requestOptions: RequestOptions(path: ''),
        data: bytes,
        headers: Headers.fromMap({
          'content-type': ['text/html']
        }),
      );

      final decoded = CampusResponseDecoder.decodeResponseBytes(response);
      expect(decoded, '测试');
    });

    test('intercepts WebVPN Access Denied', () {
      final html = '<html><body>对不起，您没有权限访问该资源</body></html>';
      expect(
        () => CampusResponseDecoder.interceptHtmlErrors(html),
        throwsA(isA<WebVpnAccessDeniedException>()),
      );
    });

    test('intercepts CAS Login Failed', () {
      final html = '<html><body><div id="msg" class="errors">密码错误或账户不存在</div></body></html>';
      expect(
        () => CampusResponseDecoder.interceptHtmlErrors(html),
        throwsA(isA<CasLoginFailedException>()),
      );
    });
  });
}
