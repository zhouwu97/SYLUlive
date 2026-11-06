import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/features/ai_device_bridge/device_credential_store.dart';
import 'package:shenliyuan/features/campus_data/erke/erke_parser.dart';
import 'package:shenliyuan/features/campus_data/erke/erke_repository.dart';
import 'package:shenliyuan/features/campus_data/storage/erke_cache_store.dart';
import 'package:shenliyuan/features/personal_data_sync/erke_snapshot_upload.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/platform/contracts/secure_store.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/screens/erke_score_screen.dart';
import 'package:shenliyuan/services/webvpn_service.dart';

import '../helpers/golden_test_app.dart';
import '../helpers/golden_viewport.dart';
import '../helpers/load_test_fonts.dart';

class _Auth extends AuthProvider {
  _Auth() : super(Dio(), loadStoredAuth: false);
  int account = 77;
  int epoch = 0;
  bool loggedIn = true;
  @override
  User get user => User(
      id: account,
      studentId: 'fixture-$account',
      nickname: '测试同学',
      createdAt: DateTime(2026));
  @override
  bool get isLoggedIn => loggedIn;
  @override
  int get accountSessionEpoch => epoch;
  void switchAccount(int id) {
    account = id;
    epoch++;
    notifyListeners();
  }
}

class _Repo extends ErkeRepository {
  _Repo(String user, String student, WebVpnService vpn, {this.cached = true})
      : super(
            vpnService: vpn,
            cacheStore:
                ErkeCacheStore(appUserId: user, sourceAccountId: student));
  final bool cached;
  Completer<void>? gate;
  bool fail = false;
  int queries = 0;
  @override
  Future<void> loadCache() async {
    if (cached) _data();
  }

  void _data() {
    graduation = ErkeParser.parseGraduationSummary(
        File('test/features/campus_data/erke/fixture_graduation.html')
            .readAsStringSync());
    yearly = ErkeParser.parseYearlySummary(
        File('test/features/campus_data/erke/fixture_yearly.html')
            .readAsStringSync());
    fetchedAt = DateTime(2026, 11, 1, 9, 0);
    hasCachedData = true;
  }

  @override
  Future<bool> loginAndFetch(
      String studentId, String casPassword, String erkePassword) async {
    queries++;
    fetchError = null;
    await gate?.future;
    if (fail) {
      fetchError = '学校服务连接超时，请重试';
      failureCategory = ErkeFetchFailureCategory.networkUnavailable;
      return false;
    }
    credentialsVerified = true;
    hasLiveSession = true;
    _data();
    return true;
  }
}

const _saved = DeviceErkeCredentials(
    casPassword: 'fixture-cas', erkePassword: 'fixture-erke');

class _SlowStore extends DeviceCredentialStore {
  _SlowStore() : super(secretStore: MemorySecretStore());
  final gate = Completer<DeviceErkeCredentials?>();
  @override
  Future<DeviceErkeCredentials?> readErke(String sourceAccountId) =>
      gate.future;
}

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  final directory = Platform.environment['ERKE_QA_DIR'];
  if (directory == null) return;
  await tester.runAsync(() async {
    final image =
        await (key.currentContext!.findRenderObject()! as RenderRepaintBoundary)
            .toImage();
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory(directory).create(recursive: true);
      await File('$directory/$name.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() async {
    AppPreferencesStore.setMockInitialValues({});
    await PreferenceErkeSnapshotUploadPolicyStore(appUserId: '77')
        .write(ErkeSnapshotUploadPolicy.neverUpload);
  });

  testWidgets('安全存储读取未完成也先展示已有成绩', (tester) async {
    final auth = _Auth();
    final store = _SlowStore();
    late _Repo repo;
    await tester.pumpWidget(ChangeNotifierProvider<AuthProvider>.value(
        value: auth,
        child: GoldenTestApp(
            home: ErkeScoreScreen(
                credentialStore: store,
                createRepository: (u, s, vpn) => repo = _Repo(u, s, vpn)))));
    await tester.pump();
    expect(find.text('毕业要求完成度'), findsOneWidget);
    expect(repo.queries, 0);
    store.gate.complete(null);
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    auth.dispose();
  });

  testWidgets('同一账号重新登录也重建二课上下文，旧更新不能卡住新页面', (tester) async {
    final auth = _Auth();
    final store = DeviceCredentialStore(secretStore: MemorySecretStore());
    await store.writeErke('fixture-77', _saved);
    final repos = <_Repo>[];
    await tester.pumpWidget(ChangeNotifierProvider<AuthProvider>.value(
        value: auth,
        child: GoldenTestApp(
            home: ErkeScoreScreen(
                credentialStore: store,
                createRepository: (u, s, vpn) {
                  final repo = _Repo(u, s, vpn);
                  repos.add(repo);
                  return repo;
                }))));
    await tester.pumpAndSettle();
    repos.first.gate = Completer<void>();
    await tester.tap(find.widgetWithText(TextButton, '更新'));
    await tester.pump(const Duration(milliseconds: 100));
    auth.switchAccount(77);
    await tester.pumpAndSettle();
    expect(repos, hasLength(2));
    repos.first.gate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('毕业要求完成度'), findsOneWidget);
    expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, '更新'))
            .onPressed,
        isNotNull);
    await tester.pumpWidget(const SizedBox());
    auth.dispose();
  });

  testWidgets('1.5 倍字号下键盘输入和提交可用', (tester) async {
    await setGoldenViewport(tester, GoldenViewports.phone360x800);
    final auth = _Auth();
    final store = DeviceCredentialStore(secretStore: MemorySecretStore());
    late _Repo repo;
    await tester.pumpWidget(ChangeNotifierProvider<AuthProvider>.value(
        value: auth,
        child: GoldenTestApp(
            textScaler: const TextScaler.linear(1.5),
            home: ErkeScoreScreen(
                credentialStore: store,
                createRepository: (u, s, vpn) =>
                    repo = _Repo(u, s, vpn, cached: false)))));
    await tester.pumpAndSettle();
    await tester.showKeyboard(find.byType(TextField).first);
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    addTearDown(tester.view.resetViewInsets);
    await tester.enterText(find.byType(TextField).at(0), 'fixture-cas');
    await tester.enterText(find.byType(TextField).at(1), 'fixture-erke');
    await tester.ensureVisible(find.text('更新二课数据'));
    await tester.tap(find.text('更新二课数据'));
    await tester.pumpAndSettle();
    expect(repo.queries, 1);
    expect(find.text('毕业要求完成度'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    auth.dispose();
  });

  testWidgets('退出登录时不建立数据保险箱，也不显示旧账号成绩', (tester) async {
    final auth = _Auth()..loggedIn = false;
    var created = 0;
    await tester.pumpWidget(ChangeNotifierProvider<AuthProvider>.value(
        value: auth,
        child:
            GoldenTestApp(home: ErkeScoreScreen(createRepository: (u, s, vpn) {
          created++;
          return _Repo(u, s, vpn);
        }))));
    await tester.pumpAndSettle();
    expect(find.text('请先在「我的」页面登录并绑定学号后查询二课成绩'), findsOneWidget);
    expect(created, 0);
    expect(find.text('毕业要求完成度'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    auth.dispose();
  });

  for (final profile in ['light', 'dark', 'large-text']) {
    testWidgets('$profile 已保存密码时保留成绩后台更新、错误恢复、退出重开', (tester) async {
      await setGoldenViewport(tester, GoldenViewports.phone360x800);
      final auth = _Auth();
      final store = DeviceCredentialStore(secretStore: MemorySecretStore());
      await store.writeErke('fixture-77', _saved);
      final repos = <_Repo>[];
      final capture = GlobalKey();
      Widget app() => ChangeNotifierProvider<AuthProvider>.value(
            value: auth,
            child: GoldenTestApp(
              themeMode: profile == 'dark' ? ThemeMode.dark : ThemeMode.light,
              textScaler: profile == 'large-text'
                  ? const TextScaler.linear(1.3)
                  : TextScaler.noScaling,
              home: RepaintBoundary(
                  key: capture,
                  child: ErkeScoreScreen(
                    credentialStore: store,
                    createRepository: (user, student, vpn) {
                      final repo = _Repo(user, student, vpn)
                        ..gate = Completer<void>();
                      repos.add(repo);
                      return repo;
                    },
                  )),
            ),
          );
      await tester.pumpWidget(app());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(repos.single.queries, 1);
      expect(find.text('毕业要求完成度'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsWidgets);
      await _capture(tester, capture, '$profile-loading');
      repos.single.fail = true;
      repos.single.gate!.complete();
      await tester.pumpAndSettle();
      expect(find.text('重试'), findsOneWidget);
      expect(find.text('毕业要求完成度'), findsOneWidget);
      expect(await store.readErke('fixture-77'), isNotNull);
      await _capture(tester, capture, '$profile-error');
      repos.single.fail = false;
      repos.single.gate = null;
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(repos.single.queries, 2);
      expect(find.byType(TextField), findsNothing);
      await _capture(tester, capture, '$profile-success');
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('学年要求'));
      await tester.pumpAndSettle();
      await _capture(tester, capture, '$profile-yearly');
      expect(tester.takeException(), isNull);

      // 页面销毁再打开仍使用同一安全存储，不依赖 TextEditingController 内存。
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(app());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(repos.last.queries, 1);
      repos.last.gate!.complete();
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    });
  }

  for (final remember in [true, false]) {
    testWidgets('首次验证保存选择：$remember', (tester) async {
      final auth = _Auth();
      final store = DeviceCredentialStore(secretStore: MemorySecretStore());
      late _Repo repo;
      await tester.pumpWidget(ChangeNotifierProvider<AuthProvider>.value(
          value: auth,
          child: GoldenTestApp(
              home: ErkeScoreScreen(
                  credentialStore: store,
                  createRepository: (u, s, vpn) =>
                      repo = _Repo(u, s, vpn, cached: false)))));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(0), 'fixture-cas');
      await tester.enterText(find.byType(TextField).at(1), 'fixture-erke');
      if (!remember) {
        await tester.ensureVisible(find.byType(CheckboxListTile));
        await tester.tap(find.byType(CheckboxListTile));
      }
      await tester.ensureVisible(find.text('更新二课数据'));
      await tester.tap(find.text('更新二课数据'));
      await tester.pumpAndSettle();
      expect(repo.queries, 1);
      expect((await store.readErke('fixture-77'))?.erkePassword,
          remember ? 'fixture-erke' : isNull);
      await tester.tap(find.text('更新'));
      await tester.pumpAndSettle();
      expect(repo.queries, 2, reason: '未选择保存也可在当前页面直接重试');
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    });
  }

  testWidgets('账号通知到页面重绑定之间，旧更新回调不能发起请求', (tester) async {
    final auth = _Auth();
    final store = DeviceCredentialStore(secretStore: MemorySecretStore());
    await store.writeErke('fixture-77', _saved);
    final repos = <_Repo>[];
    await tester.pumpWidget(ChangeNotifierProvider<AuthProvider>.value(
        value: auth,
        child: GoldenTestApp(
            home: ErkeScoreScreen(
                credentialStore: store,
                createRepository: (u, s, vpn) {
                  final repo = _Repo(u, s, vpn);
                  repos.add(repo);
                  return repo;
                }))));
    await tester.pumpAndSettle();
    expect(repos.first.queries, 1);
    final update =
        tester.widget<TextButton>(find.widgetWithText(TextButton, '更新'));
    auth.switchAccount(88);
    update.onPressed!();
    await tester.pumpAndSettle();
    expect(repos.first.queries, 1);
    expect(repos.last.queries, 0);
    await tester.pumpWidget(const SizedBox());
    auth.dispose();
  });

  testWidgets('账号切换后旧请求不能触发新账号凭据写入或上传', (tester) async {
    final auth = _Auth();
    final store = DeviceCredentialStore(secretStore: MemorySecretStore());
    await store.writeErke('fixture-77', _saved);
    final repos = <_Repo>[];
    await tester.pumpWidget(ChangeNotifierProvider<AuthProvider>.value(
        value: auth,
        child: GoldenTestApp(
            home: ErkeScoreScreen(
                credentialStore: store,
                createRepository: (u, s, vpn) {
                  final repo = _Repo(u, s, vpn, cached: false)
                    ..gate = Completer<void>();
                  repos.add(repo);
                  return repo;
                }))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    auth.switchAccount(88);
    await tester.pumpAndSettle();
    repos.first.gate!.complete();
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNWidgets(2));
    expect(find.text('毕业要求完成度'), findsNothing);
    expect(repos.last.queries, 0);
    expect(await store.readErke('fixture-88'), isNull);
    await tester.pumpWidget(const SizedBox());
    auth.dispose();
  });
}
