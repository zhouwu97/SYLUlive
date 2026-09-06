import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/post.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/post_provider.dart';
import 'package:shenliyuan/services/forbidden_recovery_router.dart';
import 'package:shenliyuan/widgets/required_legal_consent_dialog.dart';

import 'helpers/golden_viewport.dart';

/// 按序返回预设响应的 HttpClientAdapter。
class _QueuedAuthAdapter implements HttpClientAdapter {
  final List<({int statusCode, Object? data})> _responses = [];
  final List<RequestOptions> requests = [];

  void enqueue(int statusCode, Object? data) {
    _responses.add((statusCode: statusCode, data: data));
  }

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    await requestStream?.drain<void>();
    requests.add(options);
    if (_responses.isEmpty) throw StateError('缺少认证响应: ${options.path}');
    final response = _responses.removeAt(0);
    return ResponseBody.fromString(
      jsonEncode(response.data),
      response.statusCode,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }
}

/// 可把某个请求挂起、直到测试释放其响应的适配器，用于模拟“旧请求晚返回”。
class _HoldableQueuedAdapter implements HttpClientAdapter {
  final List<({int statusCode, Object? data})> _responses = [];
  Completer<void>? _hold;
  Completer<void>? _heldSignal;

  void enqueue(int statusCode, Object? data) {
    _responses.add((statusCode: statusCode, data: data));
  }

  /// 让下一个 fetch 在返回预设响应前一直等待，直到 [release]。
  void holdNext() {
    _hold = Completer<void>();
    _heldSignal = Completer<void>();
  }

  /// 请求已进入挂起态（onRequest 已执行、凭据上下文已被请求捕获）时完成。
  Future<void> get held => _heldSignal?.future ?? Future<void>.value();

  void release() {
    final hold = _hold;
    _hold = null;
    hold?.complete();
  }

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    await requestStream?.drain<void>();
    final hold = _hold;
    if (hold != null) {
      _heldSignal?.complete();
      await hold.future;
    }
    if (_responses.isEmpty) throw StateError('缺少认证响应: ${options.path}');
    final response = _responses.removeAt(0);
    return ResponseBody.fromString(
      jsonEncode(response.data),
      response.statusCode,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }
}

class _FakeAuthCredentialStore implements AuthCredentialStore {
  StoredAuthCredentials stored = const StoredAuthCredentials();
  int writeCount = 0;
  int clearCount = 0;

  @override
  Future<StoredAuthCredentials> read() async => stored;

  @override
  Future<void> write({required String token, required String userJson}) async {
    writeCount++;
    stored = StoredAuthCredentials(token: token, userJson: userJson);
  }

  @override
  Future<void> clear() async {
    clearCount++;
    stored = const StoredAuthCredentials();
  }
}

/// 阻塞下一次 clear，直到测试释放；用于验证“清理过程中重新登录保留新会话”。
class _BlockingClearStore extends _FakeAuthCredentialStore {
  final Completer<void> clearStarted = Completer<void>();
  final Completer<void> releaseClear = Completer<void>();
  bool blockNextClear = false;

  @override
  Future<void> clear() async {
    if (blockNextClear) {
      blockNextClear = false;
      clearStarted.complete();
      await releaseClear.future;
    }
    super.clear();
  }
}

Future<void> _ignoreError(Future<dynamic> future) {
  return future.then<void>((_) {}, onError: (Object _, StackTrace __) {});
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
    const MethodChannel('shenliyuan/grade_reminders'),
    (_) async => null,
  );
  messenger.setMockMethodCallHandler(
    const MethodChannel('shenliyuan/private_message_notifications'),
    (_) async => null,
  );
  messenger.setMockMethodCallHandler(
    const MethodChannel('shenliyuan/notification_open'),
    (_) async => true,
  );
  setUp(() {
    AppPreferencesStore.setMockInitialValues({});
  });

  AuthProvider makeProvider(HttpClientAdapter adapter,
      {AuthCredentialStore? store,
      Future<bool> Function()? onCommunityRulesRequired}) {
    final dio = Dio(BaseOptions(baseUrl: 'https://couqie.ccwu.cc/api'))
      ..httpClientAdapter = adapter;
    return AuthProvider(
      dio,
      credentialStore: store ?? _FakeAuthCredentialStore(),
      loadStoredAuth: false,
      onAuthenticated: () {},
      onCommunityRulesRequired: onCommunityRulesRequired,
    );
  }

  group('非终结 401 一律不清除会话', () {
    test('401 无 code（旧服务端业务错误）不退出', () async {
      final adapter = _QueuedAuthAdapter()..enqueue(401, {'error': 'APP 密码错误'});
      final provider = makeProvider(adapter);
      await provider.applyAuthPayload('token', _userJson(1));
      final generation = provider.sessionGeneration;

      await _ignoreError(provider.dio.get('/protected'));
      await pumpEventQueue(times: 20);

      expect(provider.token, 'token');
      expect(provider.authState, AuthState.authenticated);
      expect(provider.sessionGeneration, generation);
    });

    test('401 code=INVALID_PASSWORD（密码类业务错误）不退出', () async {
      final adapter = _QueuedAuthAdapter()
        ..enqueue(401, {'code': 'INVALID_PASSWORD', 'error': 'APP 密码错误'});
      final provider = makeProvider(adapter);
      await provider.applyAuthPayload('token', _userJson(1));
      final generation = provider.sessionGeneration;

      await _ignoreError(provider.dio.get('/protected'));
      await pumpEventQueue(times: 20);

      expect(provider.token, 'token');
      expect(provider.sessionGeneration, generation);
    });

    test('/edu/* 返回终结 401 也不退出 App', () async {
      final adapter = _QueuedAuthAdapter()
        ..enqueue(401, {'code': 'invalid_token', 'error': '教务会话失效'});
      final provider = makeProvider(adapter);
      await provider.applyAuthPayload('token', _userJson(1));
      final generation = provider.sessionGeneration;

      await _ignoreError(provider.dio.get('/edu/refresh'));
      await pumpEventQueue(times: 20);

      expect(provider.token, 'token');
      expect(provider.sessionGeneration, generation);
    });
  });

  group('终结 401 才退出，且必须绑定当前会话', () {
    for (final code in [
      'invalid_token',
      'token_version_expired',
      'role_changed'
    ]) {
      test('当前会话收到 $code 正确退出', () async {
        final adapter = _QueuedAuthAdapter()
          ..enqueue(401, {'code': code, 'error': '凭据失效'});
        final provider = makeProvider(adapter);
        await provider.applyAuthPayload('token', _userJson(1));
        final generation = provider.sessionGeneration;

        await _ignoreError(provider.dio.get('/protected'));
        await pumpEventQueue(times: 20);

        expect(provider.token, isNull);
        expect(provider.user, isNull);
        expect(provider.authState, AuthState.guest);
        expect(provider.sessionGeneration, generation + 1);
      });
    }

    test('旧 Token 请求的终结 401 不能删除新会话', () async {
      final adapter = _HoldableQueuedAdapter()
        ..enqueue(401, {'code': 'token_version_expired', 'error': 'x'});
      final provider = makeProvider(adapter);
      await provider.applyAuthPayload('old-token', _userJson(1));

      adapter.holdNext();
      final requestFuture = provider.dio.get('/protected');
      await adapter.held;
      // 请求已携带旧 Token 发出，响应还在路上时，会话已切换到新 Token（如教务绑定/改密）。
      await provider.applyAuthPayload('new-token', _userJson(2));
      adapter.release();

      await _ignoreError(requestFuture);
      await pumpEventQueue(times: 20);

      expect(provider.token, 'new-token');
      expect(provider.user?.id, 2);
      expect(provider.authState, AuthState.authenticated);
    });

    test('请求发出时无 Token，恢复登录后回来的终结 401 不能删除新会话', () async {
      final adapter = _HoldableQueuedAdapter()
        ..enqueue(401, {'code': 'authentication_required', 'error': 'x'});
      final provider = makeProvider(adapter);

      adapter.holdNext();
      final requestFuture = provider.dio.get('/protected');
      await adapter.held;
      // 请求发出时是 guest；响应返回前登录恢复完成。
      await provider.applyAuthPayload('token', _userJson(1));
      adapter.release();

      await _ignoreError(requestFuture);
      await pumpEventQueue(times: 20);

      expect(provider.token, 'token');
      expect(provider.authState, AuthState.authenticated);
    });
  });

  group('并发与异步竞态', () {
    test('20 个并发终结 401 只清理一次会话', () async {
      final adapter = _QueuedAuthAdapter();
      final store = _FakeAuthCredentialStore();
      final provider = makeProvider(adapter, store: store);
      await provider.applyAuthPayload('token', _userJson(1));
      for (var i = 0; i < 20; i++) {
        adapter.enqueue(401, {'code': 'invalid_token', 'error': 'x'});
      }

      await Future.wait([
        for (var i = 0; i < 20; i++) _ignoreError(provider.dio.get('/p$i')),
      ]);
      await pumpEventQueue(times: 50);

      expect(store.clearCount, 1);
      expect(provider.token, isNull);
      expect(provider.authState, AuthState.guest);
    });

    test('清理过程中重新登录，最终保留新会话', () async {
      final adapter = _QueuedAuthAdapter();
      final store = _BlockingClearStore();
      final provider = makeProvider(adapter, store: store);
      await provider.applyAuthPayload('old-token', _userJson(1));

      adapter.enqueue(401, {'code': 'invalid_token', 'error': 'x'});
      store.blockNextClear = true;
      await _ignoreError(provider.dio.get('/protected'));
      await store.clearStarted.future;

      adapter.enqueue(200, {'token': 'new-token', 'user': _userJson(2)});
      final loginFuture = provider.login('account', 'password');
      await pumpEventQueue(times: 20);
      store.releaseClear.complete();
      final result = await loginFuture;
      await pumpEventQueue(times: 20);

      expect(result.success, isTrue, reason: result.errorMessage);
      expect(provider.token, 'new-token');
      expect(provider.user?.id, 2);
      expect(provider.authState, AuthState.authenticated);
    });
  });

  group('统一 403 恢复路由', () {
    test('协议接口返回异常结构后释放加载状态，可再次确认', () async {
      final adapter = _QueuedAuthAdapter()
        ..enqueue(200, {'unexpected': true})
        ..enqueue(200, {'user': _userJson(1)});
      final provider = makeProvider(adapter);
      await provider.applyAuthPayload('token', _userJson(1));
      expect((await provider.acceptRequiredLegalConsents(includeEduDataConsent: false)).success, false);
      expect(provider.isLoading, false);
      expect((await provider.acceptRequiredLegalConsents(includeEduDataConsent: false)).success, true);
      expect(provider.isLoading, false);
    });

    testWidgets('教务本地状态缺失时按服务端提示补充勾选并成功关闭', (tester) async {
      await setGoldenViewport(tester, GoldenViewports.phone360x800);
      final adapter = _QueuedAuthAdapter()
        ..enqueue(400, {
          'code': 'edu_data_consent_required',
          'error': '使用教务认证前请阅读并同意教务数据专项授权',
        })
        ..enqueue(200, {'user': _userJson(1)});
      late AuthProvider provider;
      await tester.runAsync(() async {
        provider = makeProvider(adapter);
        await provider.applyAuthPayload('token', _userJson(1));
      });
      await tester.pumpWidget(ChangeNotifierProvider.value(
        value: provider,
        child: MaterialApp(
          theme: ThemeData.dark(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: GoldenTextProfile.large.scaler),
            child: child!,
          ),
          home: Builder(builder: (context) => Scaffold(body: TextButton(
            onPressed: () => showRequiredLegalConsentDialog(context, requiresEduDataConsent: false),
            child: const Text('打开'),
          ))),
        ),
      ));
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('required-general-consents')));
      await tester.pump();
      final confirm = find.byKey(const ValueKey('required-consent-confirm'));
      await tester.runAsync(() async {
        await tester.tap(confirm);
        await pumpEventQueue(times: 30);
      });
      await tester.pumpAndSettle();
      final edu = find.byKey(const ValueKey('required-edu-consent'));
      expect(edu, findsOneWidget);
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
      await tester.ensureVisible(edu);
      await tester.tap(edu);
      await tester.pump();
      await tester.runAsync(() async {
        await tester.tap(confirm);
        await pumpEventQueue(times: 30);
      });
      await tester.pumpAndSettle();
      expect(find.byType(RequiredLegalConsentDialog), findsNothing);
      expect((adapter.requests.first.data as Map)['edu_data_consent_accepted'], false);
      expect((adapter.requests.last.data as Map)['edu_data_consent_accepted'], true);
      expect(tester.takeException(), isNull);
    });

    for (final multipart in [false, true]) {
      test('社区确认后恢复带幂等键的${multipart ? "评论表单" : "私信"}', () async {
        final adapter = _QueuedAuthAdapter()
          ..enqueue(403, {'code': 'community_rules_required'})
          ..enqueue(201, {'id': 7});
        var confirmations = 0;
        final provider = makeProvider(adapter, onCommunityRulesRequired: () async {
          confirmations++;
          return true;
        });
        await provider.applyAuthPayload('token', _userJson(1));
        final body = {'content': '测试内容', 'file_ids': '12'};
        final response = await provider.dio.post(
          multipart ? '/posts/1/replies' : '/messages/2',
          data: multipart ? FormData.fromMap(body) : body,
          options: Options(headers: {'Idempotency-Key': 'stable-write'}),
        );
        expect(response.statusCode, 201);
        expect(confirmations, 1);
        expect(adapter.requests, hasLength(2));
        expect(adapter.requests.last.headers['Idempotency-Key'], 'stable-write');
        if (multipart) {
          expect(Map.fromEntries((adapter.requests.last.data as FormData).fields),
              body);
        }
      });
    }

    testWidgets('社区规则单独确认后完成原点赞，后续点赞不重复弹窗', (tester) async {
      await setGoldenViewport(tester, GoldenViewports.phone360x800);
      final adapter = _QueuedAuthAdapter()
        ..enqueue(403, {'code': 'community_rules_required'})
        ..enqueue(500, {'error': '保存社区规则确认失败'})
        ..enqueue(200, {'message': '已确认社区规则'})
        ..enqueue(201, {'id': 1})
        ..enqueue(201, {'id': 2});
      final navigatorKey = GlobalKey<NavigatorState>();
      late AuthProvider provider;
      var dialogCount = 0;
      await tester.runAsync(() async {
        provider = makeProvider(adapter, onCommunityRulesRequired: () {
          dialogCount++;
          return showRequiredCommunityRulesDialog(navigatorKey.currentContext!);
        });
        await provider.applyAuthPayload('token', {
          ..._userJson(1),
          'edu_bound': true,
          'edu_authorized': true,
        });
      });
      await tester.pumpWidget(ChangeNotifierProvider.value(
        value: provider,
        child: MaterialApp(
          navigatorKey: navigatorKey,
          theme: ThemeData.dark(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: GoldenTextProfile.large.scaler,
            ),
            child: child!,
          ),
          home: const Scaffold(body: Text('帖子列表')),
        ),
      ));
      final posts = PostProvider(provider.dio, enableCache: false);
      Post post(int id) => Post(
            id: id,
            title: '帖子 $id',
            content: '测试内容',
            boardId: 1,
            authorId: 2,
            createdAt: DateTime(2026, 9, 6),
          );
      late Future<LikeMutationResult> pendingLike;
      await tester.runAsync(() async {
        pendingLike = posts.toggleLikeOptimistic(post(1));
        await pumpEventQueue(times: 30);
      });
      await tester.pumpAndSettle();
      expect(find.text('请确认社区规则'), findsOneWidget);
      expect(find.byKey(const ValueKey('required-edu-consent')), findsNothing);
      expect(provider.user?.legalConsentsActive, isTrue);
      expect(provider.user?.eduAuthorized, isTrue);
      expect(posts.isLikePending(1), isTrue);
      final confirm = find.byKey(const ValueKey('required-consent-confirm'));
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
      await tester.tap(find.byKey(const ValueKey('required-general-consents')));
      await tester.pump();
      await tester.runAsync(() async {
        await tester.tap(confirm);
        await pumpEventQueue(times: 30);
      });
      await tester.pumpAndSettle();
      expect(find.text('保存社区规则确认失败'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(confirm);
        final firstLike = await pendingLike;
        expect(firstLike.status, LikeMutationStatus.success);
        expect(firstLike.optimisticPost?.isLiked, isTrue);
        expect((await posts.toggleLikeOptimistic(post(2))).status,
            LikeMutationStatus.success);
      });
      await tester.pumpAndSettle();
      expect(find.byType(RequiredLegalConsentDialog), findsNothing);
      expect(dialogCount, 1);
      expect(posts.isLikePending(1), isFalse);
      expect(provider.lastForbiddenRecovery, isNull);
      expect(adapter.requests.map((request) => request.path), [
        '/posts/1/like',
        '/user/community-rules',
        '/user/community-rules',
        '/posts/1/like',
        '/posts/2/like',
      ]);
      expect(adapter.requests[1].data, {'accepted': true});
      expect(tester.takeException(), isNull);
    });

    test('并发社区限制只显示一个弹窗，弹窗异常后所有请求正常结束', () async {
      final adapter = _QueuedAuthAdapter()
        ..enqueue(403, {'code': 'community_rules_required'})
        ..enqueue(403, {'code': 'community_rules_required'});
      final confirmation = Completer<bool>();
      var dialogCount = 0;
      final provider = makeProvider(adapter, onCommunityRulesRequired: () {
        dialogCount++;
        return confirmation.future;
      });
      await provider.applyAuthPayload('token', _userJson(1));
      final first = expectLater(provider.dio.post('/posts/1/like'),
          throwsA(isA<DioException>()));
      final second = expectLater(provider.dio.post('/posts/2/like'),
          throwsA(isA<DioException>()));
      await pumpEventQueue(times: 30);
      expect(dialogCount, 1);
      confirmation.completeError(StateError('dialog unavailable'));
      await Future.wait([first, second]);
      expect(adapter.requests, hasLength(2));
    });

    for (final scenario in ['cancel', 'switch_account', 'rejected_again', 'publish']) {
      test('社区确认恢复不会误重放: $scenario', () async {
        final adapter = _QueuedAuthAdapter()
          ..enqueue(403, {'code': 'community_rules_required'});
        var dialogCount = 0;
        late AuthProvider provider;
        provider = makeProvider(adapter, onCommunityRulesRequired: () async {
          dialogCount++;
          if (scenario == 'switch_account') {
            await provider.applyAuthPayload('new-token', _userJson(2));
          }
          return scenario != 'cancel';
        });
        await provider.applyAuthPayload('token', _userJson(1));
        if (scenario == 'rejected_again') {
          adapter.enqueue(403, {'code': 'community_rules_required'});
        }
        await expectLater(
          provider.dio.post(scenario == 'publish' ? '/posts' : '/posts/1/like'),
          throwsA(isA<DioException>()),
        );
        expect(dialogCount, 1);
        expect(adapter.requests, hasLength(scenario == 'rejected_again' ? 2 : 1));
      });
    }

    testWidgets('教务用户点赞受限后可补签协议，提交失败可重试并关闭弹窗', (tester) async {
      await setGoldenViewport(tester, GoldenViewports.phone360x800);
      final adapter = _QueuedAuthAdapter()
        ..enqueue(403, {'code': 'legal_consent_required'})
        ..enqueue(500, {'error': '保存协议确认失败'});
      late AuthProvider provider;
      final user = {
        ..._userJson(1),
        'edu_bound': true,
        'edu_authorized': true,
        'edu_session_state': 'active',
      };
      await tester.runAsync(() async {
        provider = makeProvider(adapter);
        await provider.applyAuthPayload('token', user);
        await _ignoreError(provider.dio.post('/posts/1/like'));
        await pumpEventQueue(times: 30);
      });
      adapter.enqueue(200, {'user': user});

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: provider,
          child: MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: GoldenTextProfile.large.scaler,
              ),
              child: child!,
            ),
            home: Builder(builder: (context) {
              return Scaffold(
                body: TextButton(
                  onPressed: () => showRequiredLegalConsentDialog(
                    context,
                    requiresEduDataConsent: provider.user!.eduAuthorized,
                  ),
                  child: const Text('打开协议确认'),
                ),
              );
            }),
          ),
        ),
      );
      await tester.tap(find.text('打开协议确认'));
      await tester.pumpAndSettle();
      final general = find.byKey(const ValueKey('required-general-consents'));
      final edu = find.byKey(const ValueKey('required-edu-consent'));
      final confirm = find.byKey(const ValueKey('required-consent-confirm'));
      expect(edu, findsOneWidget);
      await tester.ensureVisible(general);
      await tester.tap(general);
      await tester.pump();
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
      await tester.ensureVisible(edu);
      await tester.tap(edu);
      await tester.pump();

      await tester.runAsync(() async {
        await tester.tap(confirm);
        await pumpEventQueue(times: 30);
      });
      await tester.pumpAndSettle();
      expect(find.text('保存协议确认失败'), findsOneWidget);
      expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
      await tester.runAsync(() async {
        await tester.tap(confirm);
        await pumpEventQueue(times: 30);
      });
      await tester.pumpAndSettle();

      final submissions = adapter.requests
          .where((request) => request.path == '/user/legal-consents');
      expect(submissions, hasLength(2));
      for (final request in submissions) {
        expect(request.data['edu_data_consent_accepted'], isTrue);
      }
      expect(provider.user?.legalConsentsActive, isTrue);
      expect(find.byType(RequiredLegalConsentDialog), findsNothing);
      expect(tester.takeException(), isNull);
    });

    for (final code in [
      'community_rules_required',
      'legal_consent_required',
      'legal_consent_withdrawn',
    ]) {
      test('$code 正确区分补签协议和撤销教务授权', () async {
        final adapter = _QueuedAuthAdapter()..enqueue(403, {'code': code});
        final store = _FakeAuthCredentialStore();
        final provider = makeProvider(adapter, store: store);
        await provider.applyAuthPayload('token', {
          ..._userJson(1),
          'edu_bound': true,
          'edu_authorized': true,
          'edu_session_state': 'active',
        });

        await _ignoreError(provider.dio.post('/posts/1/like'));
        await pumpEventQueue(times: 30);

        final keepsEduConsent = code != 'legal_consent_withdrawn';
        expect(provider.user?.legalConsentsActive,
            code == 'community_rules_required');
        expect(provider.user?.legalConsentsRequired,
            code == 'legal_consent_required');
        expect(provider.user?.eduAuthorized, keepsEduConsent);
        expect(provider.user?.eduBound, keepsEduConsent);
        expect(provider.user?.eduSessionState,
            keepsEduConsent ? 'active' : 'revoked');
        final savedUser = jsonDecode(store.stored.userJson!) as Map;
        expect(savedUser['edu_authorized'], keepsEduConsent);
        expect(provider.isLoggedIn, isTrue);
      });
    }

    test('community_rules_required 不改变基础协议和登录会话', () async {
      final adapter = _QueuedAuthAdapter()
        ..enqueue(403, {
          'code': 'community_rules_required',
          'error': '请先确认社区规则',
        });
      final store = _FakeAuthCredentialStore();
      ForbiddenRecoveryRoute? route;
      final dio = Dio(BaseOptions(baseUrl: 'https://couqie.ccwu.cc/api'))
        ..httpClientAdapter = adapter;
      final provider = AuthProvider(
        dio,
        credentialStore: store,
        loadStoredAuth: false,
        onAuthenticated: () {},
        onForbiddenRecovery: (value) => route = value,
      );
      await provider.applyAuthPayload('token', _userJson(1));
      final generation = provider.sessionGeneration;

      await _ignoreError(provider.dio.get('/community/posts'));
      await pumpEventQueue(times: 30);

      expect(route?.kind, ForbiddenRecoveryKind.communityRulesRequired);
      expect(provider.token, 'token');
      expect(provider.user?.legalConsentsActive, isTrue);
      expect(provider.user?.legalConsentsRequired, isFalse);
      expect(provider.authState, AuthState.authenticated);
      expect(provider.sessionGeneration, generation);
      expect(store.clearCount, 0);
    });

    test('admin_required 只标记管理员 UI 受限，不退出登录', () async {
      final adapter = _QueuedAuthAdapter()
        ..enqueue(403, {'code': 'admin_required'});
      ForbiddenRecoveryRoute? route;
      final provider = AuthProvider(
        Dio(BaseOptions(baseUrl: 'https://couqie.ccwu.cc/api'))
          ..httpClientAdapter = adapter,
        credentialStore: _FakeAuthCredentialStore(),
        loadStoredAuth: false,
        onAuthenticated: () {},
        onForbiddenRecovery: (value) => route = value,
      );
      await provider.applyAuthPayload('token', _userJson(1));
      final generation = provider.sessionGeneration;

      await _ignoreError(provider.dio.get('/admin/pending'));
      await pumpEventQueue(times: 20);

      expect(route?.kind, ForbiddenRecoveryKind.adminRequired);
      expect(provider.lastForbiddenRecovery?.requiresAdminUiShutdown, isTrue);
      expect(provider.token, 'token');
      expect(provider.user?.id, 1);
      expect(provider.sessionGeneration, generation);
    });
  });
}

Map<String, dynamic> _userJson(int id) {
  return {
    'id': id,
    'student_id': '2026000$id',
    'nickname': '用户$id',
    'created_at': '2026-07-13T10:00:00Z',
    'legal_consents_active': true,
    'legal_consents_required': false,
  };
}
