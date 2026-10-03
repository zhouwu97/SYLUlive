import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/features/academic/application/academic_session_controller.dart';
import 'package:shenliyuan/features/academic/data/academic_identity_client.dart';
import 'package:shenliyuan/features/academic/data/academic_provider_router_repository.dart';
import 'package:shenliyuan/features/academic/data/academic_repository_impl.dart';
import 'package:shenliyuan/features/academic/data/datasource/jiaowu_local_data_source.dart';
import 'package:shenliyuan/features/academic/data/datasource/legacy_server_data_source.dart';
import 'package:shenliyuan/features/academic/domain/academic_provider.dart';
import 'package:shenliyuan/features/academic/domain/academic_repository.dart';
import 'package:shenliyuan/features/academic/storage/local_academic_account_store.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/screens/academic_data_settings_screen.dart';

import '../helpers/golden_test_app.dart';
import '../helpers/golden_viewport.dart';
import '../helpers/load_test_fonts.dart';

class _SettingsAuth extends AuthProvider {
  _SettingsAuth(super.dio) : super(loadStoredAuth: false);

  @override
  User get user => User(
        id: 7,
        studentId: '2026000001',
        nickname: '测试用户',
        createdAt: DateTime(2026),
      );

  @override
  bool get isLoggedIn => true;
}

class _SettingsAuthUser8 extends AuthProvider {
  _SettingsAuthUser8(super.dio) : super(loadStoredAuth: false);

  @override
  User get user => User(
        id: 8,
        studentId: '2026000002',
        nickname: '测试用户2',
        createdAt: DateTime(2026),
      );

  @override
  bool get isLoggedIn => true;
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => AppPreferencesStore.setMockInitialValues({}));

  testWidgets('安全存储损坏时仅展示存储异常，清除后正确显示关闭保存', (tester) async {
    final key = 'academic_credential_v1_${sha256.convert(utf8.encode('7'))}';
    FlutterSecureStorage.setMockInitialValues({key: '{broken'});
    addTearDown(() => FlutterSecureStorage.setMockInitialValues({}));
    final dio = Dio();
    final repository = AcademicRepositoryImpl(
      local: JiaowuLocalDataSource(),
      legacy: LegacyServerDataSource(dio, networkEnabled: false),
      source: AcademicSourceKind.local,
    );
    final session = AcademicSessionController(repository: repository);
    final auth = _SettingsAuth(dio);
    addTearDown(() {
      auth.dispose();
      session.dispose();
      repository.close();
      dio.close();
    });
    await session.syncAppUser('7');
    await setGoldenViewport(tester, GoldenViewports.phone360x800);
    await tester.pumpWidget(MultiProvider(providers: [
      ChangeNotifierProvider<AuthProvider>.value(value: auth),
      ChangeNotifierProvider<AcademicSessionController>.value(value: session),
    ], child: const GoldenTestApp(home: AcademicDataSettingsScreen())));
    await tester.pumpAndSettle();
    expect(find.text('本机安全存储暂不可用，请稍后重试'), findsOneWidget);
    expect(find.text('此设备尚未保存密码'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();
    expect(find.text('已关闭密码保存'), findsOneWidget);
    expect(find.text('本机安全存储暂不可用，请稍后重试'), findsNothing);
    expect(await const FlutterSecureStorage().read(key: key), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final errorCase in [
    (
      name: '500',
      exception: (RequestOptions r) => DioException.badResponse(
            statusCode: 500,
            requestOptions: r,
            response: Response(requestOptions: r, statusCode: 500),
          )
    ),
    (
      name: '超时',
      exception: (RequestOptions r) => DioException.connectionTimeout(
            timeout: const Duration(seconds: 5),
            requestOptions: r,
          )
    ),
    (
      name: '401',
      exception: (RequestOptions r) => DioException.badResponse(
            statusCode: 401,
            requestOptions: r,
            response: Response(requestOptions: r, statusCode: 401),
          )
    ),
    (
      name: '403',
      exception: (RequestOptions r) => DioException.badResponse(
            statusCode: 403,
            requestOptions: r,
            response: Response(requestOptions: r, statusCode: 403),
          )
    ),
  ]) {
    testWidgets('首次服务端身份读取失败时本机账号显示暂未确认：${errorCase.name}', (tester) async {
      final dio = Dio()
        ..interceptors.add(InterceptorsWrapper(onRequest: (request, handler) {
          handler.reject(errorCase.exception(request));
        }));
      final legacy = AcademicRepositoryImpl(
        local: JiaowuLocalDataSource(),
        legacy: LegacyServerDataSource(dio, networkEnabled: false),
        source: AcademicSourceKind.legacy,
      );
      const identity = AcademicIdentityKey(
        appUserId: '7',
        providerId: AcademicProviderId.syluUndergraduate,
        studentId: 'U-001',
      );
      final router = AcademicProviderRouterRepository(
        legacy: legacy,
        registry: AcademicProviderRegistry(),
        identityClient: AcademicIdentityClient(dio),
      );
      final session = AcademicSessionController(
        repository: router,
        identity: identity,
      );
      final auth = _SettingsAuth(dio);
      addTearDown(() {
        auth.dispose();
        session.dispose();
        router.close();
        dio.close();
      });
      final prefs = await AppPreferencesStore.getInstance();
      await LocalAcademicAccountStore('7', prefs).commitIdentity(identity);
      await session.syncAppUser('7');
      await setGoldenViewport(tester, GoldenViewports.phone360x800);
      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthProvider>.value(value: auth),
          ChangeNotifierProvider<AcademicSessionController>.value(
              value: session),
        ],
        child: const GoldenTestApp(home: AcademicDataSettingsScreen()),
      ));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('本机已配置，学生认证状态暂未确认'),
        findsOneWidget,
      );
      expect(find.textContaining('仅本机连接，未完成学生认证'), findsNothing);
      expect(find.text('学生认证状态暂未刷新'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('服务端返回空绑定列表时显示仅本机连接未完成学生认证', (tester) async {
    final dio = Dio()
      ..interceptors.add(InterceptorsWrapper(onRequest: (request, handler) {
        handler.resolve(Response(
          requestOptions: request,
          statusCode: 200,
          data: {'identities': <dynamic>[]},
        ));
      }));
    final legacy = AcademicRepositoryImpl(
      local: JiaowuLocalDataSource(),
      legacy: LegacyServerDataSource(dio, networkEnabled: false),
      source: AcademicSourceKind.legacy,
    );
    const identity = AcademicIdentityKey(
      appUserId: '7',
      providerId: AcademicProviderId.syluUndergraduate,
      studentId: 'U-001',
    );
    final router = AcademicProviderRouterRepository(
      legacy: legacy,
      registry: AcademicProviderRegistry(),
      identityClient: AcademicIdentityClient(dio),
    );
    final session = AcademicSessionController(
      repository: router,
      identity: identity,
    );
    final auth = _SettingsAuth(dio);
    addTearDown(() {
      auth.dispose();
      session.dispose();
      router.close();
      dio.close();
    });
    final prefs = await AppPreferencesStore.getInstance();
    await LocalAcademicAccountStore('7', prefs).commitIdentity(identity);
    await session.syncAppUser('7');
    await setGoldenViewport(tester, GoldenViewports.phone360x800);
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>.value(value: auth),
        ChangeNotifierProvider<AcademicSessionController>.value(
            value: session),
      ],
      child: const GoldenTestApp(home: AcademicDataSettingsScreen()),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('仅本机连接，未完成学生认证'), findsOneWidget);
    expect(find.textContaining('学生认证状态暂未确认'), findsNothing);
    expect(find.text('学生认证状态暂未刷新'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('服务端返回学校认证时显示已完成学生认证', (tester) async {
    final dio = Dio()
      ..interceptors.add(InterceptorsWrapper(onRequest: (request, handler) {
        handler.resolve(Response(
          requestOptions: request,
          statusCode: 200,
          data: {
            'identities': [
              {
                'provider_id': AcademicProviderId.syluUndergraduate.value,
                'student_id': 'U-001',
                'is_school_verified': true,
                'verification_method': academicVerificationMethodSchoolProfile,
                'verified': true,
              }
            ]
          },
        ));
      }));
    final legacy = AcademicRepositoryImpl(
      local: JiaowuLocalDataSource(),
      legacy: LegacyServerDataSource(dio, networkEnabled: false),
      source: AcademicSourceKind.legacy,
    );
    const identity = AcademicIdentityKey(
      appUserId: '7',
      providerId: AcademicProviderId.syluUndergraduate,
      studentId: 'U-001',
    );
    final router = AcademicProviderRouterRepository(
      legacy: legacy,
      registry: AcademicProviderRegistry(),
      identityClient: AcademicIdentityClient(dio),
    );
    final session = AcademicSessionController(
      repository: router,
      identity: identity,
    );
    final auth = _SettingsAuth(dio);
    addTearDown(() {
      auth.dispose();
      session.dispose();
      router.close();
      dio.close();
    });
    final prefs = await AppPreferencesStore.getInstance();
    await LocalAcademicAccountStore('7', prefs).commitIdentity(identity);
    await session.syncAppUser('7');
    await setGoldenViewport(tester, GoldenViewports.phone360x800);
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>.value(value: auth),
        ChangeNotifierProvider<AcademicSessionController>.value(
            value: session),
      ],
      child: const GoldenTestApp(home: AcademicDataSettingsScreen()),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('已完成学生认证'), findsOneWidget);
    expect(find.textContaining('学生认证状态暂未确认'), findsNothing);
    expect(find.text('学生认证状态暂未刷新'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('成功读取后再次刷新遇到错误保留历史快照并标明上次确认', (tester) async {
    var fail = false;
    final dio = Dio()
      ..interceptors.add(InterceptorsWrapper(onRequest: (request, handler) {
        if (fail) {
          handler.reject(DioException(
            requestOptions: request,
            type: DioExceptionType.badResponse,
            response: Response(requestOptions: request, statusCode: 500),
          ));
          return;
        }
        handler.resolve(Response(
          requestOptions: request,
          statusCode: 200,
          data: {
            'identities': [
              {
                'provider_id': AcademicProviderId.syluUndergraduate.value,
                'student_id': 'U-001',
                'is_school_verified': true,
                'verification_method': academicVerificationMethodSchoolProfile,
                'verified': true,
              }
            ]
          },
        ));
      }));
    final legacy = AcademicRepositoryImpl(
      local: JiaowuLocalDataSource(),
      legacy: LegacyServerDataSource(dio, networkEnabled: false),
      source: AcademicSourceKind.legacy,
    );
    const identity = AcademicIdentityKey(
      appUserId: '7',
      providerId: AcademicProviderId.syluUndergraduate,
      studentId: 'U-001',
    );
    final router = AcademicProviderRouterRepository(
      legacy: legacy,
      registry: AcademicProviderRegistry(),
      identityClient: AcademicIdentityClient(dio),
    );
    final session = AcademicSessionController(
      repository: router,
      identity: identity,
    );
    final auth = _SettingsAuth(dio);
    addTearDown(() {
      auth.dispose();
      session.dispose();
      router.close();
      dio.close();
    });
    final prefs = await AppPreferencesStore.getInstance();
    await LocalAcademicAccountStore('7', prefs).commitIdentity(identity);
    await session.syncAppUser('7');
    await setGoldenViewport(tester, GoldenViewports.phone360x800);
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>.value(value: auth),
        ChangeNotifierProvider<AcademicSessionController>.value(
            value: session),
      ],
      child: const GoldenTestApp(home: AcademicDataSettingsScreen()),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('已完成学生认证'), findsOneWidget);

    // 触发刷新并失败，重新挂载设置页测试页面呈现
    fail = true;
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>.value(value: auth),
        ChangeNotifierProvider<AcademicSessionController>.value(
            value: session),
      ],
      child: const GoldenTestApp(home: AcademicDataSettingsScreen()),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('上次成功确认：已完成学生认证'), findsOneWidget);
    expect(find.text('学生认证状态暂未刷新'), findsOneWidget);
    expect(find.textContaining('显示上次成功确认的状态'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('A/B 切号时不串染上一账号的认证状态', (tester) async {
    var userId = '7';
    final dio = Dio()
      ..interceptors.add(InterceptorsWrapper(onRequest: (request, handler) {
        if (userId == '7') {
          handler.resolve(Response(
            requestOptions: request,
            statusCode: 200,
            data: {
              'identities': [
                {
                  'provider_id': AcademicProviderId.syluUndergraduate.value,
                  'student_id': 'U-001',
                  'is_school_verified': true,
                  'verification_method':
                      academicVerificationMethodSchoolProfile,
                  'verified': true,
                }
              ]
            },
          ));
        } else {
          handler.reject(DioException(
            requestOptions: request,
            type: DioExceptionType.badResponse,
            response: Response(requestOptions: request, statusCode: 500),
          ));
        }
      }));
    final legacy = AcademicRepositoryImpl(
      local: JiaowuLocalDataSource(),
      legacy: LegacyServerDataSource(dio, networkEnabled: false),
      source: AcademicSourceKind.legacy,
    );
    const identity7 = AcademicIdentityKey(
      appUserId: '7',
      providerId: AcademicProviderId.syluUndergraduate,
      studentId: 'U-001',
    );
    const identity8 = AcademicIdentityKey(
      appUserId: '8',
      providerId: AcademicProviderId.syluUndergraduate,
      studentId: 'U-002',
    );
    final router = AcademicProviderRouterRepository(
      legacy: legacy,
      registry: AcademicProviderRegistry(),
      identityClient: AcademicIdentityClient(dio),
    );
    final session = AcademicSessionController(
      repository: router,
      identity: identity7,
    );
    final auth7 = _SettingsAuth(dio);
    final auth8 = _SettingsAuthUser8(dio);
    addTearDown(() {
      auth7.dispose();
      auth8.dispose();
      session.dispose();
      router.close();
      dio.close();
    });
    final prefs = await AppPreferencesStore.getInstance();
    await LocalAcademicAccountStore('7', prefs).commitIdentity(identity7);
    await LocalAcademicAccountStore('8', prefs).commitIdentity(identity8);
    await session.syncAppUser('7');
    await setGoldenViewport(tester, GoldenViewports.phone360x800);
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>.value(value: auth7),
        ChangeNotifierProvider<AcademicSessionController>.value(
            value: session),
      ],
      child: const GoldenTestApp(home: AcademicDataSettingsScreen()),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('已完成学生认证'), findsOneWidget);

    // 切换到用户 8
    userId = '8';
    await session.syncAppUser('8');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>.value(value: auth8),
        ChangeNotifierProvider<AcademicSessionController>.value(
            value: session),
      ],
      child: const GoldenTestApp(home: AcademicDataSettingsScreen()),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('已完成学生认证'), findsNothing);
    expect(find.textContaining('上次成功确认'), findsNothing);
    expect(find.textContaining('本机已配置，学生认证状态暂未确认'), findsOneWidget);
    expect(find.text('学生认证状态暂未刷新'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final theme in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets('身份管理移除旧服务器授权说明，资料保存关闭可取消：${theme.name}', (tester) async {
      final dio = Dio();
      final repository = AcademicRepositoryImpl(
        local: JiaowuLocalDataSource(),
        legacy: LegacyServerDataSource(dio, networkEnabled: false),
        source: AcademicSourceKind.legacy,
      );
      final session = AcademicSessionController(repository: repository);
      final auth = _SettingsAuth(dio);
      addTearDown(() {
        auth.dispose();
        session.dispose();
        repository.close();
        dio.close();
      });
      await session.syncAppUser('7');
      await setGoldenViewport(tester, GoldenViewports.phone360x800);
      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthProvider>.value(value: auth),
          ChangeNotifierProvider<AcademicSessionController>.value(
              value: session),
        ],
        child: GoldenTestApp(
          themeMode: theme,
          textScaler: GoldenTextProfile.large.scaler,
          home: const AcademicDataSettingsScreen(),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('安全保存登录凭据'), findsNothing);
      expect(find.text('断开本次会话'), findsNothing);
      expect(find.text('删除本机教务账号'), findsNothing);
      expect(find.text('服务器管理教务绑定'), findsNothing);
      expect(find.text('添加教务账号'), findsOneWidget);
      expect(find.byType(Switch), findsOneWidget);
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
      expect(tester.takeException(), isNull);

      await tester.ensureVisible(find.byType(Switch));
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(find.textContaining('自定义课程、隐藏记录和存档'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  }
}
