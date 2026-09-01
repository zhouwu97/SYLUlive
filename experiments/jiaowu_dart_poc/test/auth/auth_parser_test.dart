import 'dart:io';

import 'package:jiaowu_dart_poc/jiaowu_dart.dart';
import 'package:test/test.dart';

String _fixture(String path) => File(path).readAsStringSync();

void main() {
  group('CsrfParser', () {
    test('提取 token 并丢弃逗号后的第二段', () {
      final html = _fixture('test/fixtures/login/login_page_200.html');

      expect(CsrfParser.parse(html), 'TEST_CSRF');
    });

    test('不依赖属性顺序和引号样式', () {
      final html = _fixture(
        'test/fixtures/login/login_page_reordered_attributes.html',
      );

      expect(CsrfParser.parse(html), 'TEST_CSRF_REORDERED');
    });

    test('缺少 token 时分类为登录页变化', () {
      expect(
        () => CsrfParser.parse('<form><input name="yhm"></form>'),
        throwsA(isA<LoginPageChangedException>()),
      );
    });
  });

  group('LoginPageDetector', () {
    test('识别 200 登录 HTML', () {
      expect(
        LoginPageDetector.isLoginPage(
          _fixture('test/fixtures/login/login_page_200.html'),
        ),
        isTrue,
      );
    });

    test('普通学生信息 HTML 不是登录页', () {
      expect(
        LoginPageDetector.isLoginPage(
          _fixture('test/fixtures/profile/profile_normal.html'),
        ),
        isFalse,
      );
    });

    test('登录页关键字大小写不影响识别', () {
      expect(
        LoginPageDetector.isLoginPage(
          '<html><form action="/XTGL/LOGIN_SLOGIN.HTML"></form></html>',
        ),
        isTrue,
      );
    });

    test('单独出现登录路径的脚本不应误判为登录页', () {
      expect(
        LoginPageDetector.isLoginPage(
          '<script>location = "/xtgl/login_slogin.html";</script>',
        ),
        isFalse,
      );
    });

    test('只有辅助文字且没有表单不应误判为登录页', () {
      expect(LoginPageDetector.isLoginPage('<p>用户登录</p>'), isFalse);
    });

    test('yhm 和 mm 输入对是登录页强证据', () {
      expect(
        LoginPageDetector.isLoginPage(
          '<form><input name="yhm"><input name="mm"></form>',
        ),
        isTrue,
      );
    });
  });

  test('明确账号密码错误才分类为凭据错误', () {
    final body = _fixture(
      'test/fixtures/login/login_page_invalid_credentials.html',
    );

    expect(ErrorParser.credentialErrorMessage(body), '教务账号或密码错误');
    expect(ErrorParser.credentialErrorMessage('<title>统一认证</title>'), isNull);
  });
}
