import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jiaowu_dart_poc/jiaowu_dart.dart' hide AcademicCapabilities;
import 'package:provider/provider.dart';
import 'package:shenliyuan/features/academic/application/academic_session_controller.dart';
import 'package:shenliyuan/features/academic/domain/academic_provider.dart';
import 'package:shenliyuan/features/academic/domain/academic_repository.dart';
import 'package:shenliyuan/features/academic/storage/academic_connection_store.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/edu_provider.dart';
import 'package:shenliyuan/screens/edu_screen.dart';
import '../helpers/golden_test_app.dart';
import '../helpers/golden_viewport.dart';
import '../helpers/load_test_fonts.dart';

class _ProfileRepository implements AcademicRepository {
  bool fail = true;
  @override
  AcademicSourceKind get sourceKind => AcademicSourceKind.local;
  @override
  AcademicCapabilities get capabilities => const AcademicCapabilities.local();
  @override
  SessionState get sessionState => SessionState.authenticated;
  @override
  String get studentId => 'CURRENT';
  @override
  Future<void> resetSession() async {}
  @override
  Future<StudentProfile> getProfile() async {
    if (fail) throw const ProtocolChangedException();
    return const StudentProfile(
        name: '测试', grade: '2024', college: '当前学院', major: '当前专业');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUpAll(loadTestFonts);
  for (final theme in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets('资料读取失败后可独立重试，不显示未知占位 ${theme.name}', (tester) async {
      AppPreferencesStore.setMockInitialValues({});
      const identity = AcademicIdentityKey(
          appUserId: '7',
          providerId: AcademicProviderId.syluUndergraduate,
          studentId: 'CURRENT');
      await AcademicConnectionStore(
              identity, await AppPreferencesStore.getInstance())
          .setConnected(true);
      final repository = _ProfileRepository();
      final session =
          AcademicSessionController(repository: repository, identity: identity);
      await session.syncAppUser('7');
      final dio = Dio();
      final auth = AuthProvider(dio, loadStoredAuth: false);
      final edu = EduProvider(dio)..setAcademicSessionController(session);
      addTearDown(() {
        edu.dispose();
        auth.dispose();
        session.dispose();
        dio.close();
      });
      await setGoldenViewport(tester, GoldenViewports.phone360x800);
      await tester.pumpWidget(MultiProvider(
          providers: [
            ChangeNotifierProvider<AuthProvider>.value(value: auth),
            ChangeNotifierProvider<EduProvider>.value(value: edu),
            ChangeNotifierProvider<AcademicSessionController>.value(
                value: session),
          ],
          child: GoldenTestApp(
              themeMode: theme,
              textScaler: GoldenTextProfile.large.scaler,
              home: const EduScreen())));
      await tester.pumpAndSettle();
      expect(find.text('个人资料尚未加载完成'), findsOneWidget);
      await tester.tap(find.text('重新读取资料'));
      await tester.pumpAndSettle();
      expect(find.text('个人资料读取失败，请重试'), findsOneWidget);
      expect(session.isAuthenticated, isTrue);
      repository.fail = false;
      await tester.tap(find.text('重新读取资料'));
      await tester.pumpAndSettle();
      expect(find.text('2024级 · 当前学院'), findsOneWidget);
      expect(find.text('当前专业'), findsOneWidget);
      expect(find.textContaining('未知'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
