import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/platform/continuation/continuation_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('接续状态只编码页面字段，不包含认证凭据', () {
    const state = ContinuationState(
      route: 'competition_detail',
      competitionId: 42,
      filter: 'recommended',
      noteDraft: '待确认报名时间',
    );

    final encoded = state.encode();
    final json = jsonDecode(encoded) as Map<String, dynamic>;
    expect(json, {
      'schemaVersion': 1,
      'route': 'competition_detail',
      'competitionId': 42,
      'filter': 'recommended',
      'noteDraft': '待确认报名时间',
    });
    expect(encoded, isNot(contains('token')));
    expect(encoded, isNot(contains('password')));
  });

  test('非法 schema、路由和竞赛编号不会被恢复', () {
    expect(ContinuationState.tryParse('{"schemaVersion":2}'), isNull);
    expect(
      ContinuationState.tryParse(
        '{"schemaVersion":1,"route":"home","competitionId":42}',
      ),
      isNull,
    );
    expect(
      ContinuationState.tryParse(
        '{"schemaVersion":1,"route":"competition_detail","competitionId":0}',
      ),
      isNull,
    );
    expect(ContinuationState.tryParse('not-json'), isNull);
  });

  test('合法接续状态可往返解析', () {
    const source = ContinuationState(
      route: 'competition_detail',
      competitionId: 7,
    );
    final restored = ContinuationState.tryParse(source.encode());
    expect(restored?.route, source.route);
    expect(restored?.competitionId, source.competitionId);
    expect(restored?.filter, isNull);
  });

  test('OHOS 服务使用 stateJson 参数保存并支持清理', () async {
    const channel = MethodChannel('com.sylulive.harmony/continuation');
    final calls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final service = OhosContinuationService(channel: channel);
    const state = ContinuationState(
      route: 'competition_detail',
      competitionId: 99,
    );
    await service.save(state);
    await service.clear();

    expect(calls.map((call) => call.method), ['saveState', 'clearState']);
    expect(
      (calls.first.arguments as Map<Object?, Object?>)['stateJson'],
      state.encode(),
    );
  });
}
