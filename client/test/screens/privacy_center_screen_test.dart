import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/screens/privacy_center_screen.dart';

class _PrivacyAdapter implements HttpClientAdapter {
  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    await requestStream?.drain<void>();
    if (options.path == '/user/privacy/requests') {
      return ResponseBody.fromString(
        jsonEncode({'items': []}),
        200,
        headers: {
          Headers.contentTypeHeader: ['application/json']
        },
      );
    }
    throw StateError('未预期的隐私请求: ${options.path}');
  }
}

class _PrivacyStore implements AuthCredentialStore {
  @override
  Future<void> clear() async {}

  @override
  Future<void> deleteEduPassword(String studentId) async {}

  @override
  Future<StoredAuthCredentials> read() async => const StoredAuthCredentials();

  @override
  Future<String?> readEduPassword(String studentId) async => null;

  @override
  Future<void> write({required String token, required String userJson}) async {}

  @override
  Future<void> writeEduPassword(String studentId, String password) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
    const MethodChannel('shenliyuan/keep_alive'),
    (_) async => true,
  );
  messenger.setMockMethodCallHandler(
    const MethodChannel('shenliyuan/grade_reminders'),
    (_) async => null,
  );
  messenger.setMockMethodCallHandler(
    const MethodChannel('shenliyuan/private_message_notifications'),
    (_) async => null,
  );

  testWidgets('正常模式将查阅和导出作为直接操作，仅允许更正或删除请求', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final provider = await _provider(active: true, required: false);
    await tester.pumpWidget(_screen(provider));
    await tester.pumpAndSettle();

    expect(find.text('查阅个人信息'), findsOneWidget);
    expect(find.text('导出个人数据'), findsOneWidget);
    expect(find.text('申请更正或删除'), findsOneWidget);
    expect(find.text('撤销全部同意'), findsOneWidget);
    expect(find.text('重新授权'), findsNothing);
  });

  testWidgets('受限模式仅保留数据权利、重新授权、注销和退出登录', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final provider = await _provider(active: false, required: false);
    await tester.pumpWidget(_screen(provider, restricted: true));
    await tester.pumpAndSettle();

    expect(find.text('授权已撤销，社区、教务、消息等功能已停止使用。'), findsOneWidget);
    expect(find.text('查阅个人信息'), findsOneWidget);
    expect(find.text('导出个人数据'), findsOneWidget);
    expect(find.text('重新授权'), findsOneWidget);
    expect(find.text('申请更正或删除'), findsNothing);
    expect(find.text('撤销全部同意'), findsNothing);
    expect(find.byTooltip('退出登录'), findsOneWidget);
  });
}

Future<AuthProvider> _provider({
  required bool active,
  required bool required,
}) async {
  final dio = Dio(BaseOptions(baseUrl: 'https://sylulive.online/api'))
    ..httpClientAdapter = _PrivacyAdapter();
  final provider = AuthProvider(
    dio,
    credentialStore: _PrivacyStore(),
    loadStoredAuth: false,
    onAuthenticated: () {},
  );
  await provider.applyAuthPayload('token', {
    'id': 1,
    'student_id': '20260001',
    'nickname': '测试用户',
    'created_at': '2026-07-18T00:00:00Z',
    'legal_consents_active': active,
    'legal_consents_required': required,
  });
  return provider;
}

Widget _screen(AuthProvider provider, {bool restricted = false}) {
  return ChangeNotifierProvider<AuthProvider>.value(
    value: provider,
    child: MaterialApp(home: PrivacyCenterScreen(restricted: restricted)),
  );
}
