import 'dart:async';

import 'package:dio/dio.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/features/academic/storage/academic_storage_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/academic/application/academic_session_controller.dart';
import 'package:shenliyuan/features/academic/data/academic_repository_impl.dart';
import 'package:shenliyuan/features/academic/data/datasource/jiaowu_local_data_source.dart';
import 'package:shenliyuan/features/academic/data/datasource/legacy_server_data_source.dart';
import 'package:shenliyuan/features/academic/domain/academic_repository.dart';
import 'package:shenliyuan/features/academic/presentation/academic_login_dialog.dart';
import 'package:shenliyuan/providers/edu_provider.dart';

import '../../helpers/golden_test_app.dart';
import '../../helpers/golden_viewport.dart';
import '../../helpers/load_test_fonts.dart';

void main() {
  setUpAll(loadTestFonts);
  late Dio dio;
  late AcademicSessionController controller;
  late EduProvider provider;
  late List<RequestOptions> requests;
  bool authorized = false;
  bool rejectRevoke = false;
  bool expireSession = false;
  bool rejectResume = false;
  int revokeStatus = 200;
  Completer<void>? loginGate;

  void initialize() {
    AppPreferencesStore.setMockInitialValues({});
    authorized = false;
    rejectRevoke = false;
    expireSession = false;
    rejectResume = false;
    revokeStatus = 200;
    loginGate = null;
    requests = [];
    dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) async {
        requests.add(options);
        if (options.path == '/edu/bind') {
          if (loginGate != null) await loginGate!.future;
          authorized = true;
        }
        if (options.path == '/edu/session/resume') {
          if (rejectResume) {
            handler.reject(DioException(
              requestOptions: options,
              type: DioExceptionType.connectionError,
              message: '网络连接失败',
            ));
            return;
          }
          expireSession = false;
        }
        if (options.path == '/edu/authorization') {
          if (rejectRevoke) {
            handler.reject(DioException(
              requestOptions: options,
              type: DioExceptionType.connectionError,
              message: '网络连接失败',
            ));
            return;
          }
          authorized = false;
        }
        handler.resolve(Response(
          requestOptions: options,
          statusCode: options.path == '/edu/authorization' ? revokeStatus : 200,
          data: {
            'success': true,
            'edu_authorized': authorized,
            'edu_student_id': authorized ? '2026000001' : '',
            'edu_session_state':
                authorized ? (expireSession ? 'expired' : 'active') : 'unbound',
          },
        ));
      },
    ));
    final repository = AcademicRepositoryImpl(
      local: JiaowuLocalDataSource(),
      legacy: LegacyServerDataSource(dio, networkEnabled: true),
      source: AcademicSourceKind.legacy,
    );
    controller = AcademicSessionController(repository: repository);
    provider = EduProvider(dio)..setAcademicSessionController(controller);
    addTearDown(() {
      provider.dispose();
      controller.dispose();
      repository.close();
      dio.close();
    });
  }

  Future<void> openDialog(
    WidgetTester tester, {
    bool saveData = false,
    ThemeMode theme = ThemeMode.light,
    TextScaler scaler = TextScaler.noScaling,
  }) async {
    await tester.runAsync(() async {
      initialize();
      final preferences = AcademicStoragePreferences(
          appUserId: 'test-app-user',
          store: await AppPreferencesStore.getInstance());
      await preferences.setSaveAcademicData(saveData);
      await controller.syncAppUser('test-app-user');
    });
    await setGoldenViewport(tester, GoldenViewports.phone360x800);
    await tester.pumpWidget(GoldenTestApp(
      themeMode: theme,
      textScaler: scaler,
      home: Scaffold(
          body: Builder(
              builder: (context) => TextButton(
                    onPressed: () => AcademicLoginDialog.show(
                      context,
                      controller: controller,
                    ),
                    child: const Text('打开绑定'),
                  ))),
    ));
    await tester.tap(find.text('打开绑定'));
    await tester.pumpAndSettle();
  }

  for (final saveData in [false, true]) {
    testWidgets('绑定保留资料缓存选择 $saveData，明确授权后发送且禁止重复提交', (tester) async {
      await openDialog(tester, saveData: saveData);
      expect(find.text('绑定教务账号'), findsOneWidget);
      expect(find.textContaining('绑定只确认你在学校的教务身份'), findsOneWidget);
      expect(find.byType(Switch), findsNothing);
      final button = find.widgetWithText(FilledButton, '同意并绑定');
      expect(tester.widget<FilledButton>(button).onPressed, isNull);
      await tester.enterText(find.byType(TextFormField).at(0), '2026000001');
      await tester.enterText(find.byType(TextFormField).at(1), 'test-password');
      await tester.pumpAndSettle();
      expect(requests.where((r) => r.path == '/edu/bind'), isEmpty);
      await tester.ensureVisible(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      expect(
          tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
          isTrue);
      loginGate = Completer<void>();
      await tester.tap(button);
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      expect(controller.isBusy, isTrue);
      expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
          isNull);
      expect(
          tester
              .widget<TextFormField>(find.byType(TextFormField).at(1))
              .controller!
              .text,
          isEmpty);
      loginGate!.complete();
      // 凭据及缓存清理包含真实异步调用，等待弹窗完成整个登录流程。
      for (var attempt = 0;
          attempt < 100 &&
              find.byType(AcademicLoginDialog).evaluate().isNotEmpty;
          attempt++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.pumpAndSettle();
      expect(find.byType(AcademicLoginDialog), findsNothing);
      final binding = requests.singleWhere((r) => r.path == '/edu/bind');
      expect(binding.data['edu_data_consent_accepted'], isTrue);
      expect(controller.isAuthenticated, isTrue);
      final storedChoice = await tester.runAsync(() async {
        final preferences = AcademicStoragePreferences(
            appUserId: 'test-app-user',
            store: await AppPreferencesStore.getInstance());
        return preferences.saveAcademicData;
      });
      expect(storedChoice, saveData);
    });
  }

  for (final theme in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets('授权说明可打开，1.3倍字号无溢出：${theme.name}', (tester) async {
      await openDialog(tester,
          theme: theme, scaler: GoldenTextProfile.large.scaler);
      expect(tester.takeException(), isNull);
      final link = find.text('查看教务数据专项授权');
      await tester.ensureVisible(link);
      await tester.tap(link);
      await tester.pumpAndSettle();
      expect(find.textContaining('你授权本服务'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      expect(find.byType(AcademicLoginDialog), findsNothing);
      expect(requests.where((r) => r.path == '/edu/bind'), isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  test('过期会话恢复失败保留绑定，重试通过服务端凭据恢复且不重新绑定', () async {
    initialize();
    authorized = true;
    await controller.syncAppUser('test-app-user');
    expireSession = true;
    rejectResume = true;
    await expectLater(controller.restoreSession(force: true), throwsException);
    expect(controller.isAuthenticated, false);
    expect(provider.isBound, true);
    expect(controller.studentId, '2026000001');
    rejectResume = false;
    await controller.restoreSession();
    expect(controller.isAuthenticated, true);
    expect(controller.failure, isNull);
    final resumes =
        requests.where((request) => request.path == '/edu/session/resume');
    expect(resumes.length, 2);
    expect(resumes.every((request) => request.data == null), true);
    expect(requests.where((request) => request.path == '/edu/bind'), isEmpty);
  });

  test('未同意专项授权时 Provider 也不发出绑定请求', () async {
    initialize();
    expect(
        await provider.bind('2026000001', 'test-password',
            eduDataConsentAccepted: false),
        isFalse);
    expect(requests.where((r) => r.path == '/edu/bind'), isEmpty);
  });

  for (final status in [200, 202]) {
    test('解绑撤销服务器授权，重新恢复不会再次绑定：HTTP $status', () async {
      initialize();
      await controller.syncAppUser('test-app-user');
      await controller.login(
          studentId: '2026000001', password: 'test-password');
      await controller.resetSession();
      await controller.restoreSession();
      expect(controller.isAuthenticated, isTrue);
      revokeStatus = status;
      final result = await provider.unbind();
      expect(result.success, isTrue);
      expect(requests.singleWhere((r) => r.path == '/edu/authorization').method,
          'DELETE');
      await controller.restoreSession();
      expect(controller.isAuthenticated, isFalse);
      expect(provider.isBound, isFalse);
    });
  }

  test('撤销失败保留绑定状态并返回错误，允许重试', () async {
    initialize();
    await controller.syncAppUser('test-app-user');
    await controller.login(studentId: '2026000001', password: 'test-password');
    rejectRevoke = true;
    expect((await provider.unbind()).success, isFalse);
    expect(controller.isAuthenticated, isTrue);
    expect(provider.isBound, isTrue);
    rejectRevoke = false;
    expect((await provider.unbind()).success, isTrue);
    expect(provider.isBound, isFalse);
  });
}
