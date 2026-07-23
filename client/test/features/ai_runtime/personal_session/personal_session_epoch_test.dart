import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/ai_runtime/personal_session/personal_session_epoch.dart';

void main() {
  test('App 或教务账号变化会使旧请求代际失效', () {
    final session = PersonalSessionEpoch();
    session.synchronizeAccount('app-a::edu-a');
    final oldRequest = session.capture();
    expect(session.activate(oldRequest, 'old'), isTrue);

    expect(session.synchronizeAccount('app-b::edu-b'), isTrue);
    expect(session.isCurrent(oldRequest), isFalse);
    expect(session.owns(oldRequest, 'old'), isFalse);
  });

  test('旧请求 finally 不能释放新请求所有权', () {
    final session = PersonalSessionEpoch();
    session.synchronizeAccount('app-a::edu-a');
    final oldRequest = session.capture();
    session.activate(oldRequest, 'old');

    session.synchronizeAccount('app-b::edu-b');
    final newRequest = session.capture();
    expect(session.activate(newRequest, 'new'), isTrue);

    expect(session.release(oldRequest, 'old'), isFalse);
    expect(session.owns(newRequest, 'new'), isTrue);
    expect(session.release(newRequest, 'new'), isTrue);
  });

  test('主动失效会清除当前请求且递增代际', () {
    final session = PersonalSessionEpoch();
    session.synchronizeAccount('app-a::edu-a');
    final request = session.capture();
    session.activate(request, 'request');

    session.invalidate();

    expect(session.generation, request.generation + 1);
    expect(session.activeRequestId, isNull);
    expect(session.isCurrent(request), isFalse);
  });
}
