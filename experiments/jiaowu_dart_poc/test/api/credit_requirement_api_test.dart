import 'package:jiaowu_dart_poc/src/parser/credit_requirement_parser.dart';
import 'dart:io';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:test/test.dart';
import 'package:jiaowu_dart_poc/jiaowu_dart.dart';
import 'package:jiaowu_dart_poc/src/api/credit_requirement_api.dart';
import 'package:jiaowu_dart_poc/src/parser/credit_requirement_json_parser.dart';
import '../helpers/queued_http_adapter.dart';

void main() {
  const entry =
      '<select id="jg_id"><option value="wrong">旧</option><option selected value="college">当前</option></select>'
      '<select name="njdm_id"><option value="2024" selected>2024</option></select>'
      '<select id="zyh_id"><option selected="selected" value="major">专业</option></select>';
  test('沿用 Python 协议样本：当前选项 POST AJAX JSON 并保留课程完成状态', () async {
    final adapter = QueuedHttpAdapter([
      const QueuedHttpResponse(statusCode: 200, body: entry),
      QueuedHttpResponse(
          statusCode: 200,
          body: File('test/fixtures/credit_requirements/tree.json')
              .readAsStringSync(),
          headers: const {
            'content-type': ['application/json']
          }),
    ]);
    final dio = Dio(BaseOptions(baseUrl: 'https://test.local'))
      ..httpClientAdapter = adapter;
    final session = JiaowuSession()
      ..beginLogin('fixture')
      ..markAuthenticated();
    final result =
        await CreditRequirementApi(dio: dio, session: session).fetch();
    expect(result.success, true);
    expect(adapter.requests.first.queryParameters['gnmkdm'], 'N105505');
    expect(result.modules, hasLength(1));
    expect(result.modules.single.name, '美育模块（限选）');
    expect(result.modules.single.requiredCredits, 2);
    expect(result.modules.single.earnedCredits, 1.5);
    expect(result.modules.single.requiredCourseCount, 1);
    expect(result.modules.single.status, 'in_progress');
    expect(result.modules.single.toJson()['completed_course_count'], 1);
    expect(result.improvementCourses, isNotEmpty);
    expect(adapter.requests[1].data,
        {'jg_id': 'college', 'njdm_id': '2024', 'zyh_id': 'major'});
    expect(requestHeader(adapter.requests[1], 'X-Requested-With'),
        'XMLHttpRequest');
    expect(requestHeader(adapter.requests[1], 'Accept'), 'application/json');
    final course = result.modules.first.courses.first.toJson();
    expect(course['course_code'], isNotEmpty);
    expect(course['raw_status'], isNotEmpty);
    expect(course, contains('completed'));
    dio.close();
  });
  test('缺少当前选项时报告协议变化，不猜测首个专业', () async {
    final adapter = QueuedHttpAdapter([
      const QueuedHttpResponse(
          statusCode: 200,
          body: '<select id="jg_id"><option value="x">x</option></select>')
    ]);
    final dio = Dio(BaseOptions(baseUrl: 'https://test.local'))
      ..httpClientAdapter = adapter;
    final session = JiaowuSession()
      ..beginLogin('fixture')
      ..markAuthenticated();
    await expectLater(
        CreditRequirementApi(dio: dio, session: session).fetch(),
        throwsA(isA<ParseException>().having((e) => e.code, 'code',
            'CREDIT_REQUIREMENT_QUERY_PROTOCOL_CHANGED')));
    expect(adapter.requests, hasLength(1));
    expect(session.state, SessionState.authenticated);
    dio.close();
  });
  test('嵌套规则合并去重，门数和学分共同决定完成状态', () {
    final course = {
      'kch': 'a',
      'kcmc': '课程',
      'xf': '2',
      'yxxf': '2',
      'cj': '80'
    };
    final result = CreditRequirementJsonParser.parse([
      {
        'xfyqjdmc': '选修模块',
        'yqzdxf': '2',
        'kczdms': '2',
        'kcList': [course],
        'xfyqjdList': [
          {
            'xfyqjdmc': '至少修2学分',
            'kcList': [
              course,
              {'kch': 'b', 'kcmc': '替代课', 'xf': '1', 'tdbj': '1'}
            ]
          }
        ]
      }
    ]);
    final module = result.modules.single;
    expect(module.courses, hasLength(2));
    expect(module.earnedCredits, 3);
    expect(module.status, 'completed');
    expect(module.toJson()['completed_course_count'], 2);
    expect(CreditRequirementJsonParser.parse(jsonDecode('[]')).status, 'empty');
    expect(
        CreditRequirementJsonParser.parse({'unexpected': []}).success, false);
  });
  test('静态表格兼容要求明确模块标题并保留课程', () {
    final result =
        CreditRequirementParser.parse('<table><caption>基础教学 要求最低2学分</caption>'
            '<tr><th>课程号</th><th>课程名称</th><th>学分</th><th>状态</th></tr>'
            '<tr><td>A</td><td>数学</td><td>2</td><td>通过</td></tr></table>');
    expect(result.success, true);
    expect(result.modules.single.courses.single.courseId, 'A');
    expect(result.modules.single.requiredCredits, 2);
    expect(result.modules.single.earnedCredits, 2);
  });
  test('详情结构变化不破坏有效 Session', () async {
    final adapter = QueuedHttpAdapter([
      const QueuedHttpResponse(statusCode: 200, body: entry),
      const QueuedHttpResponse(statusCode: 200, body: '{"unexpected":true}'),
    ]);
    final dio = Dio(BaseOptions(baseUrl: 'https://test.local'))
      ..httpClientAdapter = adapter;
    final session = JiaowuSession()
      ..beginLogin('fixture')
      ..markAuthenticated();
    await expectLater(CreditRequirementApi(dio: dio, session: session).fetch(),
        throwsA(isA<ParseException>()));
    expect(session.state, SessionState.authenticated);
    dio.close();
  });
  for (final status in [901, 302]) {
    test('AJAX 登录失效 $status 与解析失败分离', () async {
      final adapter = QueuedHttpAdapter([
        const QueuedHttpResponse(statusCode: 200, body: entry),
        QueuedHttpResponse(statusCode: status, body: 'login'),
      ]);
      final dio = Dio(BaseOptions(baseUrl: 'https://test.local'))
        ..httpClientAdapter = adapter;
      final session = JiaowuSession()
        ..beginLogin('fixture')
        ..markAuthenticated();
      await expectLater(
          CreditRequirementApi(dio: dio, session: session).fetch(),
          throwsA(isA<SessionExpiredException>()));
      expect(session.state, SessionState.expired);
      dio.close();
    });
  }
}
