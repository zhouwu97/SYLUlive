import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('WebVPN 客户端使用系统 TLS 校验并保留二课 HTTP 代理', () {
    final crawler =
        File('lib/utils/sylu_client_crawler.dart').readAsStringSync();
    final webVpn = File('lib/services/webvpn_service.dart').readAsStringSync();

    for (final source in [crawler, webVpn]) {
      expect(source, isNot(contains('badCertificateCallback')));
    }
    expect(crawler, contains("'https://webvpn.sylu.edu.cn/http/"));
    expect(crawler, isNot(contains('/https/\$keyHex')));
  });

  test('二课页面只清理历史密码且不再持久化凭据', () {
    final source =
        File('lib/screens/erke_score_screen.dart').readAsStringSync();

    expect(source, contains("prefs.remove('erke_cas_pwd')"));
    expect(source, contains("prefs.remove('erke_erke_pwd')"));
    expect(source, isNot(contains("setString('erke_cas_pwd'")));
    expect(source, isNot(contains("setString('erke_erke_pwd'")));
    expect(source, isNot(contains('prefs.clear()')));
    expect(source, contains('final casPwd = _casPwdCtrl.text;'));
    expect(source, contains('final erkePwd = _erkePwdCtrl.text;'));
    expect(source, isNot(contains('_realCasPwd')));
    expect(source, isNot(contains('_realErkePwd')));
  });
}
