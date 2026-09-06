import 'dart:io';

import 'package:jiaowu_dart_poc/jiaowu_dart.dart';
import 'package:test/test.dart';

void main() {
  test('按 Python 字段合同解析学生信息', () {
    final html = File(
      'test/fixtures/profile/profile_normal.html',
    ).readAsStringSync();

    final profile = ProfileParser.parse(html);

    expect(profile.name, '张三');
    expect(profile.grade, '2026');
    expect(profile.college, '信息工程学院');
    expect(profile.major, '软件工程');
    expect(profile.toJson(), {
      'name': '张三',
      'grade': '2026',
      'college': '信息工程学院',
      'major': '软件工程',
    });
  });

  test('页面没有任何稳定字段时不伪造空学生信息', () {
    expect(
      () => ProfileParser.parse('<html><body>系统维护中</body></html>'),
      throwsA(isA<ProtocolChangedException>()),
    );
  });
}
