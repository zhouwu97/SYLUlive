import 'package:cookie_jar/cookie_jar.dart';
import 'package:jiaowu_dart_poc/jiaowu_dart.dart';
import 'package:test/test.dart';

void main() {
  test('resetSession 同时清 CookieJar 和 Session 状态', () async {
    final jar = CookieJar();
    await jar.saveFromResponse(
      Uri.parse('https://test.local/'),
      [Cookie('JSESSIONID', 'OLD_SESSION')],
    );
    final session = JiaowuSession()..beginLogin('2026000000');
    session.markAuthenticated();

    await session.resetSession(jar);

    expect(session.state, SessionState.unauthenticated);
    expect(session.studentId, isNull);
    expect(
      await jar.loadForRequest(Uri.parse('https://test.local/')),
      isEmpty,
    );
  });

  test('clearState 不触碰外部 CookieJar', () async {
    final jar = CookieJar();
    await jar.saveFromResponse(
      Uri.parse('https://test.local/'),
      [Cookie('route', 'OLD_ROUTE')],
    );
    final session = JiaowuSession()..beginLogin('2026000000');

    session.clearState();

    expect(session.state, SessionState.unauthenticated);
    expect(session.studentId, isNull);
    expect(
      await jar.loadForRequest(Uri.parse('https://test.local/')),
      hasLength(1),
    );
  });
}
