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
    expect(profile.studentId, 'U-001');
    expect(profile.grade, '2026');
    expect(profile.college, '信息工程学院');
    expect(profile.major, '软件工程');
    expect(profile.toJson(), {
      'name': '张三',
      'grade': '2026',
      'college': '信息工程学院',
      'major': '软件工程',
      'student_id': 'U-001',
    });
  });

  test('页面没有任何稳定字段时不伪造空学生信息', () {
    expect(
      () => ProfileParser.parse('<html><body>系统维护中</body></html>'),
      throwsA(isA<ProtocolChangedException>()),
    );
  });

  test('资料页明确返回一致学号时保留学校身份字段', () {
    final profile = ProfileParser.parse(
      '<div id="col_xh"><p>U-001</p></div>'
      '<input id="xh_id" value="U-001">'
      '<input id="curXh_id" value="U-001">'
      '<div id="col_xm"><p>张三</p></div>',
    );

    expect(profile.studentId, 'U-001');
  });

  test('资料页学号缺失或冲突时拒绝身份匹配', () {
    expect(
      () => ProfileParser.parse(
        '<div id="col_xh"><p>U-001</p></div>'
        '<input id="xh_id" value="U-001">',
      ),
      throwsA(isA<ProtocolChangedException>()),
    );
    expect(
      () => ProfileParser.parse(
        '<div id="col_xh"><p>U-001</p></div>'
        '<input id="xh_id" value="U-002">'
        '<input id="curXh_id" value="U-001">',
      ),
      throwsA(isA<ProtocolChangedException>()),
    );
  });
}
