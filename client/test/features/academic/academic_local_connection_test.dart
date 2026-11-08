import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:shenliyuan/features/academic/data/academic_identity_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:shenliyuan/features/academic/presentation/academic_login_dialog.dart';
import 'package:jiaowu_dart_poc/jiaowu_dart.dart' hide AcademicCapabilities;
import 'package:shenliyuan/features/academic/application/academic_login_coordinator.dart';
import 'package:shenliyuan/features/academic/application/academic_session_controller.dart';
import 'package:shenliyuan/features/academic/data/academic_account_config_client.dart';
import 'package:shenliyuan/features/academic/data/academic_provider_adapters.dart';
import 'package:shenliyuan/features/academic/data/academic_provider_router_repository.dart';
import 'package:shenliyuan/features/academic/data/academic_repository_impl.dart';
import 'package:shenliyuan/features/academic/data/graduate/graduate_protocol_client.dart';
import 'package:shenliyuan/features/academic/domain/academic_captcha_recognizer.dart';
import 'package:shenliyuan/features/academic/domain/academic_data_source.dart';
import 'package:shenliyuan/features/academic/domain/academic_provider.dart';
import 'package:shenliyuan/features/academic/domain/academic_repository.dart';
import 'package:shenliyuan/features/academic/storage/academic_credential_store.dart';
import 'package:shenliyuan/features/academic/storage/academic_connection_store.dart';
import 'package:shenliyuan/features/academic/storage/academic_persistence_policy.dart';
import 'package:shenliyuan/features/academic/storage/local_academic_account_store.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'academic_identity_lifecycle_test.dart' show Secrets;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => AppPreferencesStore.setMockInitialValues({}));
  Future<_Harness> setup() async {
    final h = _Harness(await AppPreferencesStore.getInstance());
    addTearDown(h.close);
    await h.session.syncAppUser('1');
    return h;
  }

  Future<ProviderSessionArtifact?> proof(_Harness h) async {
    final identity = h.session.identity;
    if (identity == null || !h.session.isAuthenticated) return null;
    return ProviderSessionArtifact(
        providerId: identity.providerId,
        studentId: identity.studentId,
        artifactVersion: 1,
        createdAt: DateTime.now(),
        validatedAt: DateTime.now(),
        opaqueProviderState: {
          'cookies': ['SID=session-fixture'],
          'session_path_prefix': ''
        });
  }

  void configurationApi(_Harness h) {
    final configs = <String, Map<String, dynamic>>{};
    h.dio.interceptors.clear();
    h.dio.interceptors.add(InterceptorsWrapper(onRequest: (r, handler) {
      if (r.method == 'GET') {
        handler.resolve(Response(
            requestOptions: r,
            statusCode: 200,
            data: {'configs': configs.values.toList()}));
      } else {
        final id = r.path.split('/').last;
        final config = {
          'provider_id': id,
          'student_id': r.data['student_id'],
          'state': 'active',
          'revision': (configs[id]?['revision'] as int? ?? 0) + 1
        };
        configs[id] = config;
        handler.resolve(Response(
            requestOptions: r, statusCode: 200, data: {'config': config}));
      }
    }));
  }

  AcademicLoginCoordinator withIdentity(_Harness h, Dio api) {
    configurationApi(h);
    return AcademicLoginCoordinator(
        controller: h.session,
        identityClient: AcademicIdentityClient(api),
        sessionExporter: () => proof(h),
        credentialStore: h.credentials,
        silentCaptcha: false,
        preferencesLoader: () async => h.preferences);
  }

  Map<String, Object?> receipt(AcademicProviderId provider) => {
        'verified': true,
        'assurance_level': 'school_verified',
        'verification_method': 'school_profile',
        'provider_id': provider.value,
        'student_id': 'A'
      };

  for (final provider in AcademicProviderId.values) {
    test('原入口本机登录成功后自动核验并登记，不上传密码：${provider.value}', () async {
      final h = await setup();
      final calls = <RequestOptions>[];
      final api = Dio();
      api.interceptors.add(InterceptorsWrapper(onRequest: (r, handler) {
        expect(h.session.isAuthenticated, true);
        calls.add(r);
        if (r.method == 'GET') {
          expect(r.path, '/student-identity');
          handler.resolve(Response(
              requestOptions: r, statusCode: 200, data: {'identities': []}));
          return;
        }
        expect(r.path, '/student-identity/verify-session');
        expect(r.data, {
          'provider_id': provider.value,
          'student_id': 'A',
          'school_session': {
            'cookies': ['SID=session-fixture'],
            if (provider == AcademicProviderId.syluGraduate)
              'session_path_prefix': ''
          }
        });
        expect(jsonEncode(r.data), isNot(contains('password-secret')));
        handler.resolve(Response(
            requestOptions: r, statusCode: 200, data: receipt(provider)));
      }));
      final coordinator = withIdentity(h, api);
      var result = await coordinator.login(
          studentId: 'A',
          password: 'password-secret',
          providerId: provider,
          saveCredentials: true,
          saveAcademicData: false);
      if (provider == AcademicProviderId.syluGraduate) {
        expect(result.needsCaptcha, true);
        expect(calls, isEmpty);
        result = await coordinator.continueLoginWithCaptcha(code: '1234');
      }
      expect(result.isSuccess, true);
      expect(calls.length, 2);
      expect((await coordinator.ensureAuthenticated()).isSuccess, true);
      expect(calls.length, 2);
    });
  }

  for (final oldState in ['declared', 'bound', 'verified']) {
    test('本机旧标记 $oldState 不能掩盖服务器缺失，自动补交', () async {
      final h = await setup();
      await h.coordinator.login(
          studentId: 'A',
          password: 'fixture',
          providerId: AcademicProviderId.syluUndergraduate,
          saveCredentials: false,
          saveAcademicData: false);
      await AcademicConnectionStore(h.session.identity!, h.preferences)
          .setBindingSyncState(oldState);
      final requests = <RequestOptions>[];
      final api = Dio()
        ..interceptors.add(InterceptorsWrapper(onRequest: (r, handler) {
          requests.add(r);
          handler.resolve(Response(
              requestOptions: r,
              statusCode: 200,
              data: r.method == 'GET'
                  ? {'identities': []}
                  : receipt(AcademicProviderId.syluUndergraduate)));
        }));
      final coordinator = withIdentity(h, api);
      addTearDown(coordinator.dispose);
      expect(await coordinator.synchronizeIdentityBinding(), isNull);
      expect(requests.map((r) => r.method), ['GET', 'POST']);
      expect(await coordinator.bindingSyncState(), 'verified');
    });
  }

  test('已有服务器身份不重复发送学校会话，记录后来缺失仍会补交', () async {
    final h = await setup();
    var existing = true;
    final requests = <RequestOptions>[];
    final api = Dio()
      ..interceptors.add(InterceptorsWrapper(onRequest: (r, handler) {
        requests.add(r);
        handler.resolve(Response(
            requestOptions: r,
            statusCode: 200,
            data: r.method == 'GET'
                ? {
                    'identities': [
                      if (existing)
                        receipt(AcademicProviderId.syluUndergraduate)
                    ]
                  }
                : receipt(AcademicProviderId.syluUndergraduate)));
      }));
    final coordinator = withIdentity(h, api);
    addTearDown(coordinator.dispose);
    await coordinator.login(
        studentId: 'A',
        password: 'fixture',
        providerId: AcademicProviderId.syluUndergraduate,
        saveCredentials: false,
        saveAcademicData: false);
    expect(requests.map((r) => r.method), ['GET']);
    existing = false;
    await coordinator.synchronizeIdentityBinding();
    expect(requests.map((r) => r.method), ['GET', 'GET', 'POST']);
    expect(await coordinator.bindingSyncState(), 'verified');
  });

  test('配置已在云端解绑时不发送旧学校会话补交', () async {
    final h = await setup();
    var existing = true;
    final api = Dio()
      ..interceptors.add(InterceptorsWrapper(onRequest: (r, handler) {
        expect(r.method, 'GET');
        handler.resolve(Response(requestOptions: r, statusCode: 200, data: {
          'identities': [
            if (existing) receipt(AcademicProviderId.syluUndergraduate)
          ]
        }));
      }));
    final coordinator = withIdentity(h, api);
    addTearDown(coordinator.dispose);
    await coordinator.login(
        studentId: 'A',
        password: 'fixture',
        providerId: AcademicProviderId.syluUndergraduate,
        saveCredentials: false,
        saveAcademicData: false);
    // 恢复一个带云端删除墓碑的快照，代表其他设备已经解绑。
    h.dio.interceptors.clear();
    h.dio.interceptors.add(InterceptorsWrapper(onRequest: (r, handler) {
      handler.resolve(Response(requestOptions: r, statusCode: 200, data: {
        'configs': [
          {
            'provider_id': 'sylu_undergraduate',
            'student_id': '',
            'state': 'deleted',
            'revision': 20
          }
        ]
      }));
    }));
    existing = false;
    await AcademicConnectionStore(h.session.identity!, h.preferences)
        .setBindingSyncState('declared');
    expect(await coordinator.synchronizeIdentityBinding(), contains('配置已变更'));
  });

  test('云端已经是当前学号时，旧配置队列冲突不阻止独立的学校核验', () async {
    final h = await setup();
    await h.coordinator.login(
        studentId: 'A',
        password: 'fixture',
        providerId: AcademicProviderId.syluUndergraduate,
        saveCredentials: false,
        saveAcademicData: false);
    final api = Dio();
    final requests = <RequestOptions>[];
    api.interceptors.add(InterceptorsWrapper(onRequest: (request, handler) {
      requests.add(request);
      handler.resolve(Response(
          requestOptions: request,
          statusCode: 200,
          data: request.method == 'GET'
              ? {'identities': []}
              : receipt(AcademicProviderId.syluUndergraduate)));
    }));
    final coordinator = withIdentity(h, api);
    addTearDown(coordinator.dispose);
    final snapshot = {
      'provider_id': 'sylu_undergraduate',
      'student_id': 'A',
      'state': 'active',
      'revision': 3
    };
    await h.router.accountStore!.update((state) {
      final entry = state['sylu_undergraduate'] as Map;
      entry['snapshot'] = snapshot;
      entry['conflict'] = true;
      entry['outbox'] = [];
    });
    h.dio.interceptors.clear();
    h.dio.interceptors.add(InterceptorsWrapper(onRequest: (request, handler) {
      expect(request.method, 'GET');
      handler.resolve(Response(requestOptions: request, statusCode: 200, data: {
        'configs': [snapshot]
      }));
    }));
    expect(await coordinator.synchronizeIdentityBinding(), isNull);
    expect(requests.map((request) => request.method), ['GET', 'POST']);
    expect(await coordinator.bindingSyncState(), 'verified');
  });

  test('学校拒绝密码时不会向 HK 上报学生绑定', () async {
    final h = await setup();
    final api = Dio();
    final calls = <RequestOptions>[];
    api.interceptors.add(InterceptorsWrapper(onRequest: (r, handler) {
      calls.add(r);
      handler.reject(DioException(requestOptions: r));
    }));
    final result = await withIdentity(h, api).login(
        studentId: 'A',
        password: 'reject',
        providerId: AcademicProviderId.syluUndergraduate,
        saveCredentials: true,
        saveAcademicData: false);
    expect(result.kind, AcademicLoginOutcomeKind.invalidCredentials);
    expect(calls, isEmpty);
    expect(h.router.accountStore!.identities, isEmpty);
  });

  test('HK 断网不影响本机登录与凭据保存，返回身份同步提示', () async {
    final h = await setup();
    final api = Dio();
    api.interceptors.add(InterceptorsWrapper(onRequest: (r, handler) {
      handler.reject(DioException(
          requestOptions: r, type: DioExceptionType.connectionError));
    }));
    final result = await withIdentity(h, api).login(
        studentId: 'A',
        password: 'password-secret',
        providerId: AcademicProviderId.syluUndergraduate,
        saveCredentials: true,
        saveAcademicData: false);
    expect(result.isSuccess, true);
    expect(result.message, contains('学生身份尚未同步'));
    expect(h.session.isAuthenticated, true);
    expect((await h.credentials.readForIdentity(h.session.identity!))?.password,
        'password-secret');
  });

  for (final provider in AcademicProviderId.values) {
    test('HK 恢复后无需教务操作即可自动同步：${provider.value}', () async {
      final h = await setup();
      final api = Dio();
      var calls = 0;
      api.interceptors.add(InterceptorsWrapper(onRequest: (r, handler) {
        calls++;
        if (calls == 1) {
          handler.reject(DioException(
              requestOptions: r, type: DioExceptionType.connectionError));
        } else if (r.method == 'GET') {
          handler.resolve(Response(
              requestOptions: r, statusCode: 200, data: {'identities': []}));
        } else {
          handler.resolve(Response(
              requestOptions: r, statusCode: 200, data: receipt(provider)));
        }
      }));
      configurationApi(h);
      final coordinator = AcademicLoginCoordinator(
        controller: h.session,
        identityClient: AcademicIdentityClient(api),
        sessionExporter: () => proof(h),
        credentialStore: h.credentials,
        silentCaptcha: false,
        preferencesLoader: () async => h.preferences,
        bindingRetryDelay: const Duration(milliseconds: 20),
      );
      var result = await coordinator.login(
          studentId: 'A',
          password: 'fixture',
          providerId: provider,
          saveCredentials: true,
          saveAcademicData: false);
      if (result.needsCaptcha) {
        result = await coordinator.continueLoginWithCaptcha(code: '1234');
      }
      expect(result.isSuccess, true);
      expect(await coordinator.bindingSyncState(), 'pending');
      await Future.doWhile(() async {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        return await coordinator.bindingSyncState() != 'verified';
      }).timeout(const Duration(seconds: 2));
      expect(calls, 3);
      expect(h.session.isAuthenticated, true);
      expect(
          await h.credentials.readForIdentity(h.session.identity!), isNotNull);
    });
  }

  for (final provider in AcademicProviderId.values) {
    test('重试计时器提前唤醒仍会补交身份：${provider.value}', () async {
      final h = await setup();
      var calls = 0;
      var wokeEarly = false;
      final api = Dio();
      addTearDown(() => api.close(force: true));
      api.interceptors.add(InterceptorsWrapper(onRequest: (r, handler) {
        calls++;
        if (calls == 1) {
          handler.reject(DioException(
              requestOptions: r, type: DioExceptionType.connectionError));
        } else {
          handler.resolve(Response(
              requestOptions: r,
              statusCode: 200,
              data:
                  r.method == 'GET' ? {'identities': []} : receipt(provider)));
        }
      }));
      configurationApi(h);
      final coordinator = AcademicLoginCoordinator(
        controller: h.session,
        identityClient: AcademicIdentityClient(api),
        sessionExporter: () => proof(h),
        credentialStore: h.credentials,
        silentCaptcha: false,
        preferencesLoader: () async => h.preferences,
        bindingRetryDelay: const Duration(milliseconds: 100),
      );
      addTearDown(coordinator.dispose);
      await runZoned(() async {
        var result = await coordinator.login(
            studentId: 'A',
            password: 'fixture',
            providerId: provider,
            saveCredentials: true,
            saveAcademicData: false);
        if (result.needsCaptcha) {
          result = await coordinator.continueLoginWithCaptcha(code: '1234');
        }
        expect(result.isSuccess, true);
        await Future.doWhile(() async {
          await Future<void>.delayed(const Duration(milliseconds: 5));
          return await coordinator.bindingSyncState() != 'verified';
        }).timeout(const Duration(seconds: 2));
      }, zoneSpecification: ZoneSpecification(
          createTimer: (self, parent, zone, duration, callback) {
        // 模拟 VM 毫秒粒度导致的提前唤醒，只改变首个后台重试计时器。
        if (!wokeEarly &&
            duration > const Duration(milliseconds: 50) &&
            duration <= const Duration(milliseconds: 100)) {
          wokeEarly = true;
          return parent.createTimer(zone, Duration.zero, callback);
        }
        return parent.createTimer(zone, duration, callback);
      }));
      expect(wokeEarly, true);
      expect(calls, 3);
      expect(h.session.isAuthenticated, true);
    });
  }

  test('重启后缺少学校会话时只查询记录，不伪造补交', () async {
    final h = await setup();
    final offline = Dio();
    offline.interceptors.add(InterceptorsWrapper(onRequest: (r, handler) {
      handler.reject(DioException(
          requestOptions: r, type: DioExceptionType.connectionError));
    }));
    final first = withIdentity(h, offline);
    await first.login(
        studentId: 'A',
        password: 'fixture',
        providerId: AcademicProviderId.syluUndergraduate,
        saveCredentials: false,
        saveAcademicData: false);
    expect(await first.bindingSyncState(), 'pending');
    first.dispose();
    final restarted = _Harness(h.preferences);
    addTearDown(restarted.close);
    await restarted.session.syncAppUser('1');
    final online = Dio();
    var calls = 0;
    online.interceptors.add(InterceptorsWrapper(onRequest: (r, handler) {
      calls++;
      handler.resolve(Response(
          requestOptions: r, statusCode: 200, data: {'identities': []}));
    }));
    final restored = withIdentity(restarted, online);
    await restored.warmUp();
    expect(calls, 1);
    expect(await restored.bindingSyncState(), 'pending');
    expect(restarted.session.isAuthenticated, false);
    expect(restarted.sources.fold(0, (n, source) => n + source.logins), 0);
  });

  test('声明回执不符合契约时停止自动重试，不再每 30 秒打扰', () async {
    final h = await setup();
    final api = Dio();
    var calls = 0;
    api.interceptors.add(InterceptorsWrapper(onRequest: (r, handler) {
      calls++;
      if (r.method == 'GET') {
        handler.resolve(Response(
            requestOptions: r, statusCode: 200, data: {'identities': []}));
        return;
      }
      // 旧式回执：自称 verified=true。这是契约错误，重试不会变好。
      handler.resolve(Response(requestOptions: r, statusCode: 200, data: {
        'verified': true,
        'provider_id': 'sylu_undergraduate',
        'student_id': 'A',
      }));
    }));
    configurationApi(h);
    final coordinator = AcademicLoginCoordinator(
      controller: h.session,
      identityClient: AcademicIdentityClient(api),
      sessionExporter: () => proof(h),
      credentialStore: h.credentials,
      silentCaptcha: false,
      preferencesLoader: () async => h.preferences,
      bindingRetryDelay: const Duration(milliseconds: 20),
    );
    final result = await coordinator.login(
        studentId: 'A',
        password: 'fixture',
        providerId: AcademicProviderId.syluUndergraduate,
        saveCredentials: true,
        saveAcademicData: false);
    // 本机登录本身仍然成功，只有身份声明被拒。
    expect(result.isSuccess, true);
    expect(result.message, contains('已停止自动重试'));
    expect(await coordinator.bindingSyncState(), 'rejected');
    await Future<void>.delayed(const Duration(milliseconds: 80));
    // 定时器不再排：契约错误被当成临时故障重试，只会反复打扰用户。
    expect(calls, 2);
  });

  test('身份登记被拒后手动重新连接可重新核验，不沿用旧错误', () async {
    final h = await setup();
    final api = Dio();
    addTearDown(() => api.close(force: true));
    var rejected = true;
    var verifications = 0;
    api.interceptors.add(InterceptorsWrapper(onRequest: (r, handler) {
      if (r.method == 'GET') {
        handler.resolve(Response(
            requestOptions: r, statusCode: 200, data: {'identities': []}));
        return;
      }
      verifications++;
      handler.resolve(Response(
          requestOptions: r,
          statusCode: rejected ? 409 : 200,
          data: rejected
              ? {'code': 'ACADEMIC_BINDING_CHANGED'}
              : receipt(AcademicProviderId.syluUndergraduate)));
    }));
    final coordinator = withIdentity(h, api);
    addTearDown(coordinator.dispose);
    Future<AcademicLoginOutcome> reconnect() => coordinator.login(
        studentId: 'A',
        password: 'fixture',
        providerId: AcademicProviderId.syluUndergraduate,
        saveCredentials: true,
        saveAcademicData: false);
    expect((await reconnect()).isSuccess, true);
    expect(await coordinator.bindingSyncState(), 'rejected');
    expect(verifications, 1);

    rejected = false;
    final result = await reconnect();
    expect(result.isSuccess, true);
    expect(result.message ?? '', isNot(contains('已停止自动重试')));
    expect(verifications, 2);
    expect(await coordinator.bindingSyncState(), 'verified');
  });

  test('账号受限时同样停止自动重试', () async {
    final h = await setup();
    final api = Dio();
    var calls = 0;
    api.interceptors.add(InterceptorsWrapper(onRequest: (r, handler) {
      calls++;
      handler.resolve(Response(
          requestOptions: r,
          statusCode: 403,
          data: {'code': 'ACCOUNT_RESTRICTED'}));
    }));
    final coordinator = AcademicLoginCoordinator(
      controller: h.session,
      identityClient: AcademicIdentityClient(api),
      credentialStore: h.credentials,
      silentCaptcha: false,
      preferencesLoader: () async => h.preferences,
      bindingRetryDelay: const Duration(milliseconds: 20),
    );
    await coordinator.login(
        studentId: 'A',
        password: 'fixture',
        providerId: AcademicProviderId.syluUndergraduate,
        saveCredentials: true,
        saveAcademicData: false);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(calls, 1);
    expect(await coordinator.bindingSyncState(), 'rejected');
  });

  test('限流计时器提前唤醒时继续等待，不绕过十分钟冷却', () async {
    final h = await setup();
    final api = Dio();
    addTearDown(() => api.close(force: true));
    var calls = 0;
    final callbacks = <void Function()>[];
    final delays = <Duration>[];
    api.interceptors.add(InterceptorsWrapper(onRequest: (r, handler) {
      calls++;
      handler.resolve(Response(
          requestOptions: r, statusCode: 429, data: {'code': 'RATE_LIMITED'}));
    }));
    final coordinator = AcademicLoginCoordinator(
      controller: h.session,
      identityClient: AcademicIdentityClient(api),
      credentialStore: h.credentials,
      preferencesLoader: () async => h.preferences,
    );
    addTearDown(coordinator.dispose);
    await runZoned(() async {
      final result = await coordinator.login(
          studentId: 'A',
          password: 'fixture',
          providerId: AcademicProviderId.syluUndergraduate,
          saveCredentials: true,
          saveAcademicData: false);
      expect(result.isSuccess, true);
      expect(calls, 1);
      expect(callbacks, hasLength(1));
      callbacks.removeAt(0)();
      expect(callbacks, hasLength(1));
      expect(delays, hasLength(2));
      expect(delays.every((delay) => delay > const Duration(minutes: 9)), true);
      expect(await coordinator.bindingSyncState(), 'pending');
      expect(calls, 1);
    }, zoneSpecification: ZoneSpecification(
        createTimer: (self, parent, zone, duration, callback) {
      if (duration > const Duration(minutes: 1)) {
        delays.add(duration);
        callbacks.add(callback);
        return parent.createTimer(zone, Duration.zero, () {});
      }
      return parent.createTimer(zone, duration, callback);
    }));
  });

  for (final action in ['disconnect', 'switch-user', 'dispose']) {
    test('停止旧身份同步后定时任务不会重新绑定：$action', () async {
      final h = await setup();
      final api = Dio();
      var calls = 0;
      api.interceptors.add(InterceptorsWrapper(onRequest: (r, handler) {
        calls++;
        handler.reject(DioException(
            requestOptions: r, type: DioExceptionType.connectionError));
      }));
      final coordinator = AcademicLoginCoordinator(
        controller: h.session,
        identityClient: AcademicIdentityClient(api),
        credentialStore: h.credentials,
        preferencesLoader: () async => h.preferences,
        bindingRetryDelay: const Duration(milliseconds: 20),
      );
      await coordinator.login(
          studentId: 'A',
          password: 'fixture',
          providerId: AcademicProviderId.syluUndergraduate,
          saveCredentials: true,
          saveAcademicData: false);
      final oldIdentity = h.session.identity!;
      if (action == 'disconnect') {
        await AcademicConnectionStore(oldIdentity, h.preferences)
            .setConnected(false);
      } else if (action == 'switch-user') {
        await h.session.syncAppUser('2');
      } else {
        coordinator.dispose();
      }
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(calls, 1);
      expect(
          AcademicConnectionStore(oldIdentity, h.preferences).bindingSyncState,
          action == 'disconnect' ? 'none' : 'pending');
    });
  }

  for (final brightness in Brightness.values) {
    testWidgets('认证授权提示支持深浅色与大字：$brightness', (tester) async {
      final h = (await tester.runAsync(setup))!;
      await tester.pumpWidget(MaterialApp(
          theme: ThemeData(brightness: brightness),
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(1.3)),
              child: child!),
          home: AcademicLoginDialog(
              controller: h.session, coordinator: h.coordinator)));
      await tester.pumpAndSettle();
      expect(find.textContaining('手机登录教务成功后'), findsOneWidget);
      expect(find.textContaining('学号由服务端确认'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final provider in AcademicProviderId.values) {
    test('清除本机数据后等待云端配置，恢复类型学号且只需补密码：${provider.value}', () async {
      final h = await setup();
      h.dio.interceptors.clear();
      final started = Completer<void>();
      final release = Completer<void>();
      h.dio.interceptors
          .add(InterceptorsWrapper(onRequest: (request, handler) async {
        if (!started.isCompleted) started.complete();
        await release.future;
        handler.resolve(Response(requestOptions: request, data: {
          'configs': [
            {
              'provider_id': provider.value,
              'student_id': 'CLOUD',
              'state': 'active',
              'revision': 3
            }
          ]
        }));
      }));
      final restoring = h.coordinator.ensureAuthenticated();
      await started.future;
      expect(h.session.identity, isNull);
      release.complete();
      final result = await restoring;
      expect(h.session.identity?.providerId, provider);
      expect(h.session.identity?.studentId, 'CLOUD');
      expect(result.kind, AcademicLoginOutcomeKind.credentialsRequired);
      expect(h.secret.values, isEmpty);
      expect(h.sources.every((source) => source.logins == 0), isTrue);
      expect(h.gateways.every((gateway) => gateway.logins == 0), isTrue);
    });
  }

  test('云端配置读取失败不能当成未绑定并要求添加账号', () async {
    final h = await setup();
    final result = await h.coordinator.ensureAuthenticated();
    expect(h.session.identity, isNull);
    expect(result.kind, isNot(AcademicLoginOutcomeKind.credentialsRequired));
    expect(h.session.failure, isNotNull);
  });

  test('本科直接本机登录，HK 断网仍成功，密码不出现在 HK 请求中', () async {
    final h = await setup();
    final result = await h.login('A', AcademicProviderId.syluUndergraduate);
    expect(result.isSuccess, true);
    expect(h.session.isAuthenticated, true);
    expect(h.router.accountStore!.identities.single.studentId, 'A');
    expect(h.sources.single.logins, 1);
    expect(h.gateways, isEmpty);
    await h.router.syncConfiguration();
    expect(
        h.requests.every((r) => r.path.startsWith('/academic-account-configs')),
        true);
    expect(h.requests.map((r) => r.data.toString()).join(),
        isNot(contains('password-secret')));
    expect((await h.credentials.readForIdentity(h.session.identity!))?.password,
        'password-secret');
  });

  test('研究生只走自己的验证码与资料协议，不调用本科登录', () async {
    final h = await setup();
    final waiting = await h.login('SAME', AcademicProviderId.syluGraduate);
    expect(waiting.needsCaptcha, true);
    expect(h.gateways.single.logins, 0);
    expect(h.sources, isEmpty);
    final result = await h.coordinator.continueLoginWithCaptcha(code: '1234');
    expect(result.isSuccess, true);
    expect(h.gateways.single.logins, 1);
    expect(h.session.identity!.providerId, AcademicProviderId.syluGraduate);
    expect(h.router.accountStore!.identities.single.studentId, 'SAME');
  });

  test('本科验证码续登调用本科 continuation，不重新提交初始登录', () async {
    final h = await setup();
    h.undergraduateCaptcha = true;
    final waiting = await h.login('A', AcademicProviderId.syluUndergraduate);
    expect(waiting.needsCaptcha, true);
    final result = await h.coordinator.continueLoginWithCaptcha(code: '9876');
    expect(result.isSuccess, true);
    expect(h.sources.single.logins, 1);
    expect(h.sources.single.continuations, 1);
  });

  test('换绑学校拒绝 B 后保留 A 的本机配置和运行时', () async {
    final h = await setup();
    await h.login('A', AcademicProviderId.syluUndergraduate);
    final old = h.session.identity;
    final result = await h.login('B', AcademicProviderId.syluUndergraduate,
        password: 'reject', change: true);
    expect(result.kind, AcademicLoginOutcomeKind.invalidCredentials);
    expect(h.session.identity, old);
    expect(h.session.isAuthenticated, true);
    expect(h.router.accountStore!.identities.single.studentId, 'A');
    expect((await h.credentials.readForIdentity(old!))?.password,
        'password-secret');
  });

  test('学校资料身份不一致时不提交本机配置也不同步新账号', () async {
    final h = await setup();
    h.mismatch = true;
    final result = await h.login('A', AcademicProviderId.syluUndergraduate);
    expect(result.isSuccess, false);
    expect(h.router.accountStore!.identities, isEmpty);
    expect(h.session.identity, isNull);
    expect(
        h.router.accountStore!
            .entry(AcademicProviderId.syluUndergraduate)['outbox'],
        isNull);
  });

  test('离线换绑 B 后重启仍选择 B，本科研究生相同学号也各自保存', () async {
    final h = await setup();
    await h.login('A', AcademicProviderId.syluUndergraduate);
    expect(
        (await h.login('B', AcademicProviderId.syluUndergraduate, change: true))
            .isSuccess,
        true);
    final undergraduate = h.session.identity!;
    await h.login('B', AcademicProviderId.syluGraduate, add: true);
    expect(
        (await h.coordinator.continueLoginWithCaptcha(code: '1234')).isSuccess,
        true);
    final graduate = h.session.identity!;
    expect(undergraduate.storageId, isNot(graduate.storageId));
    final restarted = _Harness(h.preferences);
    addTearDown(restarted.close);
    await restarted.session.syncAppUser('1');
    expect(restarted.session.identity, graduate);
    expect(LocalAcademicAccountStore('1', h.preferences).identities.toSet(),
        {undergraduate, graduate});
  });

  test('保存偏好期间切换 App 账号，凭据清理仍只作用于原登录身份', () async {
    final h = await setup();
    await h.login('A', AcademicProviderId.syluUndergraduate);
    final original = h.session.identity!;
    const other = AcademicIdentityKey(
        appUserId: '2',
        providerId: AcademicProviderId.syluUndergraduate,
        studentId: 'A');
    await h.credentials.writeForIdentity(other,
        const AcademicCredential(studentId: 'A', password: 'other-password'));
    final blockedPreferences = _BlockedPreferenceStore();
    final coordinator = AcademicLoginCoordinator(
        controller: h.session,
        credentialStore: h.credentials,
        preferencesLoader: () async => h.preferences,
        persistencePolicy: AcademicPersistencePolicy(
            appUserId: '1',
            preferences: blockedPreferences,
            academicStore: null,
            scheduleStore: null));
    final login = coordinator.login(
        studentId: 'A',
        password: 'password-secret',
        saveCredentials: false,
        saveAcademicData: false);
    await blockedPreferences.started.future;
    final switchUser = h.session.syncAppUser('2');
    blockedPreferences.release.complete();
    expect((await login).kind, AcademicLoginOutcomeKind.contextChanged);
    await switchUser;
    expect(await h.credentials.readForIdentity(original), isNull);
    expect((await h.credentials.readForIdentity(other))?.password,
        'other-password');
    expect(h.router.accountStore!.identities, isEmpty);
  });

  for (final provider in AcademicProviderId.values) {
    test('${provider.displayName}损坏凭据只报告存储异常，不要求密码或提交学校登录', () async {
      final h = await setup();
      await h.router.accountStore!.mergeSnapshot({
        'provider_id': provider.value,
        'student_id': 'SAME',
        'state': 'active',
        'revision': 1,
      });
      final identity = h.router.accountStore!.identities.single;
      final key = 'academic_credential_v2_${identity.storageId}';
      await h.secret.write(key, '{broken');
      final result = await h.coordinator.ensureAuthenticated();
      expect(result.kind, AcademicLoginOutcomeKind.failure);
      expect(result.message, contains('安全存储'));
      expect(h.sources.fold(0, (n, s) => n + s.logins), 0);
      expect(h.gateways.fold(0, (n, g) => n + g.logins), 0);
      expect(await h.secret.read(key), '{broken');
    });

    test('${provider.displayName}旧账号有明确类型时离线迁移，不生成错误云端覆盖', () async {
      AppPreferencesStore.setMockInitialValues({
        'auth_user': jsonEncode({
          'id': 1,
          'academic_provider_id': provider.value,
          'student_id': 'SAME',
        })
      });
      final h = await setup();
      final identity = h.router.accountStore!.identities.single;
      expect(identity.providerId, provider);
      expect(identity.studentId, 'SAME');
      expect(h.router.accountStore!.entry(provider)['outbox'], isNull);
    });
  }

  test('旧账号缺少教务类型时不依据学号猜测本科或研究生', () async {
    AppPreferencesStore.setMockInitialValues({
      'auth_user': jsonEncode({
        'id': 1,
        'student_id': 'SAME',
      })
    });
    final h = await setup();
    expect(h.router.accountStore!.identities, isEmpty);
  });

  test('新设备配置只补全目标学号，尚无凭据时不会向学校提交空密码', () async {
    final h = await setup();
    await h.router.accountStore!.mergeSnapshot({
      'provider_id': 'sylu_graduate',
      'student_id': 'G',
      'state': 'active',
      'revision': 3
    });
    final outcome = await h.coordinator.ensureAuthenticated();
    expect(h.session.identity?.studentId, 'G');
    expect(h.session.identity?.providerId, AcademicProviderId.syluGraduate);
    expect(outcome.kind, AcademicLoginOutcomeKind.credentialsRequired);
    expect(h.gateways.single.logins, 0);
  });
}

class _Harness {
  _Harness(this.preferences) {
    dio.interceptors.add(InterceptorsWrapper(onRequest: (r, h) {
      requests.add(r);
      h.reject(DioException(
          requestOptions: r, type: DioExceptionType.connectionError));
    }));
    final empty = _Source();
    router = AcademicProviderRouterRepository(
        legacy: AcademicRepositoryImpl(
            local: empty, legacy: empty, source: AcademicSourceKind.legacy),
        registry: AcademicProviderRegistry([
          _UndergraduateFactory((identity) {
            final s =
                _Source(captcha: undergraduateCaptcha, mismatch: mismatch);
            sources.add(s);
            return UndergraduateAcademicProvider(identity: identity, source: s);
          }),
          GraduateAcademicProviderFactory(
              gatewayFactory: () {
                final g = _Gateway();
                gateways.add(g);
                return g;
              },
              captchaRecognizer: const ManualAcademicCaptchaRecognizer()),
        ]),
        configClient: AcademicAccountConfigClient(dio));
    session = AcademicSessionController(repository: router);
    coordinator = AcademicLoginCoordinator(
        controller: session,
        credentialStore: credentials,
        silentCaptcha: false,
        preferencesLoader: () async => preferences,
        persistencePolicy: AcademicPersistencePolicy(
            appUserId: '1',
            preferences: preferences,
            academicStore: null,
            scheduleStore: null));
  }
  final AppPreferencesStore preferences;
  final dio = Dio();
  final requests = <RequestOptions>[];
  final sources = <_Source>[];
  final gateways = <_Gateway>[];
  final secret = Secrets();
  late final credentials = PlatformAcademicCredentialStore(secretStore: secret);
  late final AcademicProviderRouterRepository router;
  late final AcademicSessionController session;
  late final AcademicLoginCoordinator coordinator;
  bool undergraduateCaptcha = false;
  bool mismatch = false;
  Future<AcademicLoginOutcome> login(
          String student, AcademicProviderId provider,
          {String password = 'password-secret',
          bool change = false,
          bool add = false}) =>
      coordinator.login(
          studentId: student,
          password: password,
          providerId: provider,
          changeIdentity: change,
          addIdentity: add,
          saveCredentials: true,
          saveAcademicData: false);
  void close() {
    session.dispose();
    router.close();
    dio.close();
  }
}

class _UndergraduateFactory implements AcademicProviderFactory {
  _UndergraduateFactory(this.factory);
  final AcademicProvider Function(AcademicIdentityKey) factory;
  @override
  AcademicProviderId get id => AcademicProviderId.syluUndergraduate;
  @override
  AcademicProvider create(AcademicIdentityKey identity) => factory(identity);
}

class _Source implements AcademicDataSource {
  _Source({this.captcha = false, this.mismatch = false});
  final bool captcha;
  final bool mismatch;
  int logins = 0;
  int continuations = 0;
  String? student;
  SessionState state = SessionState.unauthenticated;
  @override
  String get sourceName => "本机测试教务";
  @override
  SessionState get sessionState => state;
  @override
  String? get studentId => student;
  @override
  Future<LoginResult> login(
      {required String studentId, required String password}) async {
    logins++;
    student = studentId;
    if (password == 'reject') return const InvalidCredentials();
    if (captcha) return const CaptchaRequired();
    state = SessionState.authenticated;
    return LoginSuccess(studentId: studentId, cookieNames: const {});
  }

  @override
  Future<LoginResult> continueLoginWithCaptcha({required String code}) async {
    continuations++;
    state = SessionState.authenticated;
    return LoginSuccess(studentId: student!, cookieNames: const {});
  }

  @override
  Future<CaptchaChallenge> getCaptchaChallenge() async =>
      CaptchaChallenge(imageBytes: Uint8List.fromList([1]));
  @override
  Future<StudentProfile> getProfile() async => StudentProfile(
      name: '测试',
      grade: '',
      college: '',
      major: '',
      studentId: mismatch ? 'WRONG' : student);
  @override
  Future<void> resetSession() async {
    state = SessionState.unauthenticated;
  }

  @override
  Future<void> restoreSession() async {}
  @override
  void close() {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Gateway implements GraduateProtocolGateway {
  String? student;
  int logins = 0;
  @override
  Future<GraduateCaptcha> prepareLogin() async =>
      GraduateCaptcha(Uint8List.fromList([1]), challengeId: 'g-captcha');
  @override
  Future<void> login(
      {required String studentId,
      required String password,
      required String captchaCode}) async {
    logins++;
    student = studentId;
  }

  @override
  Future<GraduateProfile> fetchProfile() async =>
      GraduateProfile(studentId: student);
  @override
  Future<GraduateSessionState> probe() async =>
      GraduateSessionState(authenticated: student != null, studentId: student);
  @override
  Future<void> reset() async {
    student = null;
  }

  @override
  void close() {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _BlockedPreferenceStore extends MemoryPreferencesStore {
  final started = Completer<void>();
  final release = Completer<void>();
  @override
  Future<bool> setBool(String key, bool value) async {
    if (key.startsWith('academic_save_credentials_') && !value) {
      started.complete();
      await release.future;
    }
    return super.setBool(key, value);
  }
}
