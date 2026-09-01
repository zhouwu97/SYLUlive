import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jiaowu_dart_poc/jiaowu_dart.dart';
import 'package:jiaowu_mobile_probe/main.dart';
import 'package:jiaowu_mobile_probe/src/jiaowu_gateway.dart';
import 'package:jiaowu_mobile_probe/src/probe_controller.dart';

void main() {
  testWidgets('网络诊断不需要账号，并显示 DNS、HTTPS 和 CSRF 摘要', (tester) async {
    final gateway = _FakeGateway();
    await _pump(tester, gateway);

    await tester.tap(find.widgetWithText(OutlinedButton, '网络诊断'));
    await tester.pumpAndSettle();

    expect(gateway.networkCalls, 1);
    expect(gateway.lastInsecureTls, isFalse);
    expect(find.textContaining('DNS: OK'), findsOneWidget);
    expect(find.textContaining('HTTPS: OK'), findsOneWidget);
    expect(find.textContaining('CSRF: OK'), findsOneWidget);
  });

  testWidgets('网络诊断失败时只展示安全 transport 摘要', (tester) async {
    final gateway = _FakeGateway()
      ..networkResult = JiaowuNetworkProbeResult(
        dnsSucceeded: true,
        ipv4Count: 1,
        ipv6Count: 0,
        error: NetworkException(
          code: 'TLS_HANDSHAKE_FAILED',
          message: 'HTTPS 诊断时 TLS 握手失败',
          diagnostic: const SafeTransportDiagnostic(
            operation: 'HTTPS 诊断',
            code: 'TLS_HANDSHAKE_FAILED',
            dioType: 'connectionError',
            innerType: 'HandshakeException',
            host: 'jxw.sylu.edu.cn',
          ),
        ),
      );
    await _pump(tester, gateway);

    await tester.tap(find.widgetWithText(OutlinedButton, '网络诊断'));
    await tester.pumpAndSettle();

    expect(find.textContaining('HTTPS: FAILED'), findsOneWidget);
    expect(find.textContaining('TLS_HANDSHAKE_FAILED'), findsWidgets);
    expect(find.textContaining('HandshakeException'), findsOneWidget);
    expect(find.textContaining('Cookie'), findsNothing);
    expect(find.textContaining('encrypted-secret'), findsNothing);
  });

  testWidgets('密码字段隐藏且登录后清空，不出现在安全状态中', (tester) async {
    final gateway = _FakeGateway();
    await _pump(tester, gateway);

    final passwordField = tester.widget<TextField>(
      find.byType(TextField).at(1),
    );
    expect(passwordField.obscureText, isTrue);
    expect(find.widgetWithText(OutlinedButton, 'Profile'), findsOneWidget);
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Profile'),
          )
          .onPressed,
      isNull,
    );

    await tester.enterText(find.byType(TextField).at(0), '20260001');
    await tester.enterText(find.byType(TextField).at(1), 'secret-value');
    await tester.tap(find.widgetWithText(FilledButton, '登录'));
    await tester.pumpAndSettle();

    expect(gateway.lastPassword, 'secret-value');
    expect(
      tester.widget<TextField>(find.byType(TextField).at(1)).controller!.text,
      isEmpty,
    );
    expect(find.textContaining('secret-value'), findsNothing);
    expect(find.text('Session: authenticated'), findsOneWidget);
  });

  testWidgets('登录成功后仅展示安全的 Profile 摘要', (tester) async {
    final gateway = _FakeGateway();
    await _pump(tester, gateway);
    await _login(tester);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Profile'));
    await tester.pumpAndSettle();

    expect(find.text('Profile: OK'), findsOneWidget);
    expect(find.textContaining('测试学生'), findsNothing);
    expect(find.textContaining('敏感学院'), findsNothing);
  });

  testWidgets('课表只显示记录数和来源', (tester) async {
    final gateway = _FakeGateway()
      ..courseResult = CourseFetchResult(
        courses: const [],
        source: CourseSource.desktop,
      );
    await _pump(tester, gateway);
    await _login(tester);

    await tester.tap(find.widgetWithText(OutlinedButton, '课表'));
    await tester.pumpAndSettle();

    expect(find.text('Courses: 0 records / desktop'), findsOneWidget);
  });

  testWidgets('合法空成绩是成功摘要而非错误', (tester) async {
    final gateway = _FakeGateway()
      ..gradeResult = GradeFetchResult(grades: const [], pages: 1);
    await _pump(tester, gateway);
    await _login(tester);

    await tester.tap(find.widgetWithText(OutlinedButton, '成绩'));
    await tester.pumpAndSettle();

    expect(
      find.text('Grades: 0 records / 1 pages / valid empty'),
      findsOneWidget,
    );
    expect(find.textContaining('UNEXPECTED_ERROR'), findsNothing);
  });

  testWidgets('非法学期在 UI 层被拒绝且不请求 Gateway', (tester) async {
    final gateway = _FakeGateway();
    await _pump(tester, gateway);
    await _login(tester);

    await tester.enterText(find.byType(TextField).at(3), '5');
    await tester.tap(find.widgetWithText(OutlinedButton, '课表'));
    await tester.pumpAndSettle();

    expect(gateway.courseCalls, 0);
    expect(find.textContaining('INVALID_ACADEMIC_REQUEST'), findsOneWidget);
  });

  testWidgets('会话过期显示安全错误并转为 expired', (tester) async {
    final gateway = _FakeGateway()
      ..profileError = const SessionExpiredException();
    await _pump(tester, gateway);
    await _login(tester);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Profile'));
    await tester.pumpAndSettle();

    expect(find.text('Session: expired'), findsOneWidget);
    expect(find.textContaining('SESSION_EXPIRED'), findsOneWidget);
    expect(
      tester
          .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '课表'))
          .onPressed,
      isNull,
    );
  });
}

Future<void> _pump(WidgetTester tester, _FakeGateway gateway) {
  return tester.pumpWidget(
    MobileProbeApp(controller: ProbeController(gateway)),
  );
}

Future<void> _login(WidgetTester tester) async {
  await tester.enterText(find.byType(TextField).at(0), '20260001');
  await tester.enterText(find.byType(TextField).at(1), 'secret-value');
  await tester.tap(find.widgetWithText(FilledButton, '登录'));
  await tester.pumpAndSettle();
}

final class _FakeGateway implements JiaowuGateway {
  SessionState _state = SessionState.unauthenticated;
  String? lastPassword;
  int courseCalls = 0;
  Object? profileError;
  CourseFetchResult courseResult = CourseFetchResult(
    courses: const [],
    source: CourseSource.desktop,
  );
  GradeFetchResult gradeResult = GradeFetchResult(grades: const [], pages: 1);
  JiaowuNetworkProbeResult networkResult = const JiaowuNetworkProbeResult(
    dnsSucceeded: true,
    ipv4Count: 1,
    ipv6Count: 0,
    httpsSucceeded: true,
    httpStatus: 200,
    csrfSucceeded: true,
  );
  int networkCalls = 0;
  bool? lastInsecureTls;

  @override
  SessionState get sessionState => _state;

  @override
  Future<LoginResult> login({
    required String studentId,
    required String password,
  }) async {
    lastPassword = password;
    _state = SessionState.authenticated;
    return LoginSuccess(studentId: studentId, cookieNames: const {});
  }

  @override
  Future<StudentProfile> getProfile() async {
    if (profileError != null) {
      if (profileError is SessionExpiredException) {
        _state = SessionState.expired;
      }
      throw profileError!;
    }
    return const StudentProfile(
      name: '测试学生',
      grade: '2026',
      college: '敏感学院',
      major: '测试专业',
    );
  }

  @override
  Future<CourseFetchResult> getCourses({
    required String year,
    required int semester,
  }) async {
    courseCalls++;
    return courseResult;
  }

  @override
  Future<GradeFetchResult> getGrades({
    required String year,
    required int semester,
  }) async => gradeResult;

  @override
  Future<JiaowuNetworkProbeResult> diagnoseNetwork({
    bool insecureTls = false,
  }) async {
    networkCalls++;
    lastInsecureTls = insecureTls;
    return networkResult;
  }

  @override
  void close() {}
}
