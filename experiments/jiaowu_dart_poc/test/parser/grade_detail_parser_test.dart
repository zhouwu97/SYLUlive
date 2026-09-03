import 'package:test/test.dart';
import 'package:jiaowu_dart_poc/src/parser/grade_detail_parser.dart';
import 'package:jiaowu_dart_poc/src/model/grade_component.dart';

void main() {
  group('GradeDetailParser', () {
    test('parses HTML table with grade components', () {
      const detailHtml = '''
<table>
  <tr><th>成绩分项</th><th>成绩分项比例</th><th>成绩</th></tr>
  <tr><td>【 平时 】</td><td>15%</td><td>98</td></tr>
  <tr><td>【作业】</td><td>15%</td><td>88</td></tr>
  <tr><td>【实验】</td><td>10%</td><td>81.8</td></tr>
  <tr><td>【期末】</td><td>60%</td><td>40</td></tr>
  <tr><td>【总评】</td><td></td><td>60.1</td></tr>
</table>
''';

      final detail = GradeDetailParser.parse(detailHtml, '电磁场与电磁波');

      expect(detail.success, isTrue);
      expect(detail.courseName, '电磁场与电磁波');
      expect(detail.totalGrade, '60.1');
      expect(detail.components, hasLength(5));
      expect(
        detail.components,
        containsAll([
          GradeComponent(name: '平时', weight: '15%', score: '98'),
          GradeComponent(name: '作业', weight: '15%', score: '88'),
          GradeComponent(name: '实验', weight: '10%', score: '81.8'),
          GradeComponent(name: '期末', weight: '60%', score: '40'),
          GradeComponent(name: '总评', weight: null, score: '60.1'),
        ]),
      );
    });

    test('parses JSON with items array', () {
      const body = '''
{
  "items": [
    {"cjxmmc": "平时", "xmbfb": "15%", "xmcj": "98"},
    {"cjxmmc": "总评", "xmcj": "60.1"}
  ]
}
''';

      final detail = GradeDetailParser.parse(body, '电磁场与电磁波');

      expect(detail.success, isTrue);
      expect(detail.totalGrade, '60.1');
      expect(detail.components, hasLength(2));
      expect(detail.components[0].name, '平时');
      expect(detail.components[0].weight, '15%');
      expect(detail.components[0].score, '98');
    });

    test('parses JSON with rows array', () {
      const body = '''
{
  "rows": [
    {"cjxmmc": "期末", "xmbfb": "60%", "xmcj": "85"}
  ]
}
''';

      final detail = GradeDetailParser.parse(body, '高等数学');

      expect(detail.success, isTrue);
      expect(detail.components, hasLength(1));
      expect(detail.components[0].name, '期末');
    });

    test('returns empty detail for empty response', () {
      final detail = GradeDetailParser.parse('', '课程名');

      expect(detail.success, isFalse);
      expect(detail.courseName, '课程名');
      expect(detail.totalGrade, '');
      expect(detail.components, isEmpty);
      expect(detail.message, '详情响应为空');
    });

    test('returns empty detail for JSON without components', () {
      const body = '{"items": []}';

      final detail = GradeDetailParser.parse(body, '课程名');

      expect(detail.success, isFalse);
      expect(detail.components, isEmpty);
      expect(detail.message, '详情 JSON 中没有成绩构成');
    });

    test('returns empty detail for HTML without components', () {
      const body = '<html><body><p>暂无成绩详情</p></body></html>';

      final detail = GradeDetailParser.parse(body, '课程名');

      expect(detail.success, isFalse);
      expect(detail.components, isEmpty);
      expect(detail.message, '详情 HTML 中没有成绩构成');
    });

    test('normalizes component names by removing brackets', () {
      const body = '''
{
  "items": [
    {"cjxmmc": "【平时】", "xmcj": "95"},
    {"cjxmmc": "[ 期末 ]", "xmcj": "85"}
  ]
}
''';

      final detail = GradeDetailParser.parse(body, '课程');

      expect(detail.components[0].name, '平时');
      expect(detail.components[1].name, '期末');
    });

    test('finds total grade from component with 总 character', () {
      const body = '''
{
  "items": [
    {"cjxmmc": "平时", "xmcj": "95"},
    {"cjxmmc": "期末", "xmcj": "85"},
    {"cjxmmc": "总评", "xmcj": "90"}
  ]
}
''';

      final detail = GradeDetailParser.parse(body, '课程');

      expect(detail.totalGrade, '90');
    });

    test('uses last component score as total grade when no 总 character', () {
      const body = '''
{
  "items": [
    {"cjxmmc": "平时", "xmcj": "95"},
    {"cjxmmc": "期末", "xmcj": "85"}
  ]
}
''';

      final detail = GradeDetailParser.parse(body, '课程');

      expect(detail.totalGrade, '85');
    });

    test('handles null weight in JSON', () {
      const body = '''
{
  "items": [
    {"cjxmmc": "总评", "xmcj": "90"}
  ]
}
''';

      final detail = GradeDetailParser.parse(body, '课程');

      expect(detail.components[0].weight, isNull);
    });

    test('skips JSON rows without name or score', () {
      const body = '''
{
  "items": [
    {"cjxmmc": "平时", "xmcj": "95"},
    {"cjxmmc": "", "xmcj": "85"},
    {"cjxmmc": "期末", "xmcj": ""}
  ]
}
''';

      final detail = GradeDetailParser.parse(body, '课程');

      expect(detail.components, hasLength(1));
      expect(detail.components[0].name, '平时');
    });

    test('handles nested data key in JSON', () {
      const body = '''
{
  "data": {
    "items": [
      {"cjxmmc": "平时", "xmcj": "95"}
    ]
  }
}
''';

      final detail = GradeDetailParser.parse(body, '课程');

      expect(detail.success, isTrue);
      expect(detail.components, hasLength(1));
    });

    test('handles multiple field name variations', () {
      const body = '''
{
  "items": [
    {"xmmc": "平时", "score": "95", "bl": "30%"},
    {"name": "期末", "df": "85", "weight": "70%"}
  ]
}
''';

      final detail = GradeDetailParser.parse(body, '课程');

      expect(detail.components, hasLength(2));
      expect(detail.components[0].name, '平时');
      expect(detail.components[0].weight, '30%');
      expect(detail.components[1].name, '期末');
      expect(detail.components[1].weight, '70%');
    });

    test('skips non-Map elements in JSON array', () {
      const body = '''
{
  "items": [
    null,
    "invalid string",
    123,
    {"cjxmmc": "总评", "xmcj": "85"},
    true,
    {"cjxmmc": "平时", "xmcj": "90", "bl": "20%"}
  ]
}
''';

      final detail = GradeDetailParser.parse(body, '课程');

      expect(detail.success, isTrue);
      expect(detail.components, hasLength(2));
      expect(detail.components[0].name, '总评');
      expect(detail.components[0].score, '85');
      expect(detail.components[1].name, '平时');
      expect(detail.components[1].score, '90');
      expect(detail.components[1].weight, '20%');
    });
  });
}
