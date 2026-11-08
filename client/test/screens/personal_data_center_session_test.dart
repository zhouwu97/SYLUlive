import 'dart:io';
import 'dart:ui' as ui;
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/edu_provider.dart';
import 'package:shenliyuan/screens/ai/personal_data_center_screen.dart';
import '../helpers/golden_test_app.dart';
import '../helpers/golden_viewport.dart';
import '../helpers/load_test_fonts.dart';

class _Auth extends AuthProvider {
  _Auth(super.dio) : super(loadStoredAuth: false);
  int epoch = 1;
  @override
  User get user =>
      User(id: 7, studentId: '', nickname: '合成用户', createdAt: DateTime(2026));
  @override
  bool get isLoggedIn => true;
  @override
  int get accountSessionEpoch => epoch;
  void relogin() {
    epoch++;
    notifyListeners();
  }
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => AppPreferencesStore.setMockInitialValues({}));
  for (final dark in [false, true]) {
    testWidgets('数据中心确认途中会话变化不删除新账号摘要 dark=$dark', (tester) async {
      await setGoldenViewport(tester, GoldenViewports.phone360x800);
      final dio = Dio(BaseOptions(baseUrl: 'https://fixture.invalid/api'));
      final auth = _Auth(dio);
      final edu = EduProvider(dio);
      final boundary = GlobalKey();
      var requests = 0;
      dio.interceptors.add(InterceptorsWrapper(onRequest: (request, handler) {
        requests++;
        handler.resolve(Response(requestOptions: request, statusCode: 204));
      }));
      await tester.pumpWidget(MultiProvider(
          providers: [
            ChangeNotifierProvider<AuthProvider>.value(value: auth),
            ChangeNotifierProvider<EduProvider>.value(value: edu),
          ],
          child: GoldenTestApp(
              themeMode: dark ? ThemeMode.dark : ThemeMode.light,
              textScaler: TextScaler.linear(dark ? 1.3 : 1),
              home: RepaintBoundary(
                  key: boundary,
                  child: PersonalDataCenterScreen(
                      appUserId: '7', sourceAccountId: '', dio: dio)))));
      await tester.pumpAndSettle();
      expect(find.text('更新个人数据'), findsOneWidget);
      final folder = Platform.environment['DATA_CENTER_QA_DIR'];
      if (folder != null) {
        await tester.runAsync(() async {
          final render = boundary.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
          final image = await render.toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory(folder).create(recursive: true);
          await File('$folder/center-$dark.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      final delete = find.text('删除已上传二课快照');
      await tester.scrollUntilVisible(delete, 180,
          scrollable: find.byType(Scrollable).first);
      await tester.tap(delete);
      await tester.pumpAndSettle();
      expect(find.text('确认删除'), findsOneWidget);
      auth.relogin();
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认删除'));
      await tester.pumpAndSettle();
      expect(requests, 0);
      expect(find.text('登录状态或教务身份已变化，请返回后重新打开'), findsOneWidget);
      expect(find.text('更新个人数据'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
      edu.dispose();
      dio.close();
    });
  }
}
