import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/features/academic/application/academic_session_controller.dart';
import 'package:shenliyuan/features/academic/data/academic_repository_impl.dart';
import 'package:shenliyuan/features/academic/data/datasource/jiaowu_local_data_source.dart';
import 'package:shenliyuan/features/academic/data/datasource/legacy_server_data_source.dart';
import 'package:shenliyuan/features/academic/domain/academic_repository.dart';
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

void main() {
  setUpAll(loadTestFonts);
  setUp(() => AppPreferencesStore.setMockInitialValues({}));

  for (final theme in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets('服务端模式只管理资料，默认保存且关闭可取消：${theme.name}', (tester) async {
      final dio = Dio();
      final repository = AcademicRepositoryImpl(
        local: JiaowuLocalDataSource(),
        legacy: LegacyServerDataSource(dio, networkEnabled: true),
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
      expect(find.text('服务器管理教务绑定'), findsOneWidget);
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
