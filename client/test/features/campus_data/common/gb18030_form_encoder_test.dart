import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/campus_data/common/gb18030_form_encoder.dart';

void main() {
  group('Gb18030FormEncoder', () {
    test('encodes Chinese characters and spaces correctly matching Python quote_plus', () {
      final data = {
        'username': '张三',
        'queryBtn': '跳 转',
      };
      
      final encodedBytes = Gb18030FormEncoder.encodeFormBody(data);
      final encodedString = ascii.decode(encodedBytes);
      
      // '张三' in GBK: D5 C5 C8 FD -> %D5%C5%C8%FD
      // '跳 转' in GBK: CC F8 20 D7 AA -> %CC%F8+%D7%AA
      expect(encodedString, 'username=%D5%C5%C8%FD&queryBtn=%CC%F8+%D7%AA');
    });

    test('leaves alphanumeric characters untouched', () {
      final data = {
        'foo_bar': 'abc.123-XYZ',
      };
      
      final encodedBytes = Gb18030FormEncoder.encodeFormBody(data);
      final encodedString = ascii.decode(encodedBytes);
      
      expect(encodedString, 'foo_bar=abc.123-XYZ');
    });
  });
}
