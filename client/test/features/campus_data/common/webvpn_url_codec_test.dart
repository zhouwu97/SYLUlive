import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/campus_data/common/webvpn_url_codec.dart';

void main() {
  group('WebVpnUrlCodec', () {
    test('encryptDomain matches Python crypto vectors', () {
      final file = File('test/fixtures/campus_data/crypto_vectors.json');
      final jsonStr = file.readAsStringSync();
      final data = json.decode(jsonStr);

      final vector = data['webvpn'];
      final domain = vector['domain'] as String;
      final expectedHex = vector['expected_hex'] as String;

      final encrypted = WebVpnUrlCodec.encryptDomain(domain);

      expect(encrypted, expectedHex);
    });

    test('buildHttpUrl constructs correct WebVPN URI', () {
      final uri = WebVpnUrlCodec.buildHttpUrl(
        domain: 'xg.sylu.edu.cn',
        path: '/SyluTW/Sys/SystemForm/main.htm',
      );

      expect(
        uri.toString(),
        'https://webvpn.sylu.edu.cn/http/77726476706e69737468656265737421e8f00f8f3e3c7d1e7b0c9ce29b5b/SyluTW/Sys/SystemForm/main.htm',
      );
    });
  });
}
