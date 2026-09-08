import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/features/academic/application/academic_session_controller.dart';
import 'package:shenliyuan/features/academic/data/academic_repository_impl.dart';
import 'package:shenliyuan/features/academic/data/datasource/jiaowu_local_data_source.dart';
import 'package:shenliyuan/features/academic/domain/academic_provider.dart';
import 'package:shenliyuan/features/academic/domain/academic_repository.dart';
import 'package:shenliyuan/features/academic/presentation/academic_unbind_dialog.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/edu_provider.dart';
import 'package:shenliyuan/screens/account_security_screen.dart';
import 'package:shenliyuan/widgets/settings/settings_account_header.dart';
import '../helpers/golden_test_app.dart';
import '../helpers/golden_viewport.dart';
import '../helpers/load_test_fonts.dart';

class _Auth extends AuthProvider {
  _Auth(super.dio) : super(loadStoredAuth: false);
  @override
  User get user => User(
      id: 7,
      studentId: 'OLD-GRADUATE',
      loginAccount: 'ORIGINAL',
      nickname: '测试用户',
      createdAt: DateTime(2026),
      studentVerified: true);
  @override
  bool get isLoggedIn => true;
  @override
  Future<Map<String, dynamic>?> getAccountSecurity() async => {
        'student_id': 'OLD-GRADUATE',
        'student_verified': true,
        'login_account': 'ORIGINAL',
        'login_methods': ['student_id'],
        'email_bound': false
      };
}

class _Edu extends EduProvider {
  _Edu(super.dio);
  int unbindCalls = 0;
  @override
  Future<OperationResult<void>> unbind() async {
    unbindCalls++;
    return OperationResult.ok(null);
  }
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => AppPreferencesStore.setMockInitialValues({}));
  for (final provider in AcademicProviderId.values) {
    for (final theme in [ThemeMode.light, ThemeMode.dark]) {
      testWidgets('当前教务类型与固定登录账号分开展示 ${provider.value} ${theme.name}',
          (tester) async {
        final dio = Dio();
        final auth = _Auth(dio);
        final repo = AcademicRepositoryImpl(
            local: JiaowuLocalDataSource(),
            legacy: JiaowuLocalDataSource(),
            source: AcademicSourceKind.local);
        final session = AcademicSessionController(
            repository: repo,
            identity: AcademicIdentityKey(
                appUserId: '7', providerId: provider, studentId: 'CURRENT'));
        addTearDown(() {
          auth.dispose();
          session.dispose();
          repo.close();
          dio.close();
        });
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
                home: const AccountSecurityScreen())));
        await tester.pumpAndSettle();
        expect(find.text('${provider.displayName} · CURRENT'), findsOneWidget);
        expect(find.textContaining('OLD-GRADUATE'), findsNothing);
        await tester.scrollUntilVisible(find.text('App 登录账号：ORIGINAL'), 200);
        expect(find.text('App 登录账号：ORIGINAL'), findsOneWidget);
        await tester.scrollUntilVisible(find.text('邮箱未绑定'), 150);
        await tester.tap(find.text('邮箱未绑定'));
        await tester.pumpAndSettle();
        expect(find.text('绑定邮箱'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
    testWidgets('解绑确认明确当前教务类型，取消不执行 ${provider.value}', (tester) async {
      final dio = Dio();
      final edu = _Edu(dio);
      final repo = AcademicRepositoryImpl(
          local: JiaowuLocalDataSource(),
          legacy: JiaowuLocalDataSource(),
          source: AcademicSourceKind.local);
      final session = AcademicSessionController(
          repository: repo,
          identity: AcademicIdentityKey(
              appUserId: '7', providerId: provider, studentId: 'CURRENT'));
      addTearDown(() {
        edu.dispose();
        session.dispose();
        repo.close();
        dio.close();
      });
      await setGoldenViewport(tester, GoldenViewports.phone360x800);
      await tester.pumpWidget(MultiProvider(
          providers: [
            ChangeNotifierProvider<EduProvider>.value(value: edu),
            ChangeNotifierProvider<AcademicSessionController>.value(
                value: session),
          ],
          child: GoldenTestApp(
              home: Scaffold(
                  body: Builder(
                      builder: (context) => TextButton(
                          onPressed: () => confirmAcademicUnbind(context),
                          child: const Text('打开解绑')))))));
      await tester.tap(find.text('打开解绑'));
      await tester.pumpAndSettle();
      expect(find.text('解绑${provider.displayName}？'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(edu.unbindCalls, 0);
      await tester.tap(find.text('打开解绑'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('解绑教务'));
      await tester.pumpAndSettle();
      expect(edu.unbindCalls, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
  testWidgets('设置摘要只显示固定 App 账号', (tester) async {
    final dio = Dio();
    final auth = _Auth(dio);
    addTearDown(() {
      auth.dispose();
      dio.close();
    });
    await tester.pumpWidget(ChangeNotifierProvider<AuthProvider>.value(
        value: auth,
        child: const GoldenTestApp(
            home: Scaffold(body: SettingsAccountHeader()))));
    await tester.pumpAndSettle();
    expect(find.text('App 账号：ORIGINAL'), findsOneWidget);
    expect(find.textContaining('OLD-GRADUATE'), findsNothing);
  });
}
