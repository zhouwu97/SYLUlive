import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/emoji/application/emoji_pack_download_manager.dart';
import 'package:shenliyuan/features/emoji/application/emoji_recent_manager.dart';
import 'package:shenliyuan/features/emoji/data/emoji_pack_catalog_repository.dart';
import 'package:shenliyuan/features/emoji/data/emoji_pack_local_store.dart';
import 'package:shenliyuan/features/emoji/domain/emoji_feature_flags.dart';
import 'package:shenliyuan/features/emoji/domain/emoji_pack.dart';
import 'package:shenliyuan/features/emoji/domain/emoji_pack_installation.dart';
import 'package:shenliyuan/features/emoji/domain/emoji_pack_manifest.dart';
import 'package:shenliyuan/features/emoji/presentation/emoji_download_screen.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import '../../helpers/golden_test_app.dart';
import '../../helpers/golden_viewport.dart';

const fixtureManifest = EmojiPackManifest(
    schemaVersion: 1, packId: 'test', version: 1, totalSize: 100, assets: []);
const entry = EmojiCatalogEntry(
    id: 'test',
    name: '测试官方包',
    version: 1,
    assetCount: 0,
    totalSize: 100,
    manifestSha256: 'fixture');
const installation = EmojiPackInstallation(
    manifest: fixtureManifest,
    manifestSha256: 'fixture',
    name: '测试官方包',
    trustLevel: EmojiPackTrustLevel.serverOfficial);

class _Store extends EmojiPackLocalStore {
  _Store() : super(Directory.systemTemp);
  List<EmojiPackInstallation> items = [installation];
  @override
  Future<List<EmojiPackInstallation>> load() async => items;
  @override
  Future<void> setEnabled(String id, bool value) async {
    items = items.map((p) => p.copyWith(enabled: value)).toList();
  }
}

class _Catalog extends EmojiPackCatalogRepository {
  _Catalog() : super(Dio(BaseOptions(baseUrl: 'https://example.test/api')));
  bool fail = false;
  @override
  Future<EmojiPackManifest> manifest(
      EmojiCatalogEntry entry, CancelToken token) async {
    if (fail) throw StateError('network');
    return fixtureManifest;
  }
}

class _Manager extends EmojiPackDownloadManager {
  _Manager(super.store, super.catalog, {super.flags});
  int starts = 0;
  @override
  Future<void> start(EmojiCatalogEntry entry) async {
    starts++;
    emit(EmojiDownloadStatus.downloading);
  }

  @override
  void pause(String id) => emit(EmojiDownloadStatus.paused);
  void emit(EmojiDownloadStatus status) {
    tasks[entry.id] = EmojiDownloadTask(entry, status);
    notifyListeners();
  }
}

void main() {
  testWidgets('同版本损坏包不被旧 installed 任务遮蔽；修复后停用状态保留并能启用返回', (tester) async {
    final store = _Store(), catalog = _Catalog();
    store.items = [
      installation.copyWith(
          status: EmojiPackInstallStatus.damaged, enabled: false)
    ];
    final manager = _Manager(store, catalog)
      ..emit(EmojiDownloadStatus.installed);
    String? result;
    await tester.pumpWidget(GoldenTestApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    onPressed: () async {
                      result = await Navigator.of(context).push<String>(
                          MaterialPageRoute(
                              builder: (_) => EmojiPackPreviewScreen(
                                  entry: entry,
                                  catalog: catalog,
                                  manager: manager,
                                  installation: store.items.first)));
                    },
                    child: const Text('打开'))))));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.text('重新下载并修复'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull);
    await tester.tap(find.text('重新下载并修复'));
    await tester.pump();
    expect(manager.starts, 1);
    store.items = [installation.copyWith(enabled: false)];
    manager.emit(EmojiDownloadStatus.installed);
    await tester.pumpAndSettle();
    expect(find.text('启用并使用'), findsOneWidget);
    expect(store.items.single.enabled, isFalse);
    await tester.tap(find.text('启用并使用'));
    await tester.pumpAndSettle();
    expect(result, entry.id);
    expect(store.items.single.enabled, isTrue);
  });
  testWidgets('暂停、继续、失败重试和安装锁定保留真实任务状态', (tester) async {
    final catalog = _Catalog(), manager = _Manager(_Store(), _Catalog());
    await tester.pumpWidget(GoldenTestApp(
        home: EmojiPackPreviewScreen(
            entry: entry, catalog: catalog, manager: manager)));
    await tester.pumpAndSettle();
    manager.emit(EmojiDownloadStatus.downloading);
    await tester.pump();
    await tester.tap(find.text('暂停下载'));
    await tester.pumpAndSettle();
    expect(find.text('继续下载并安装'), findsOneWidget);
    await tester.tap(find.text('继续下载并安装'));
    await tester.pump();
    expect(manager.starts, 1);
    manager.emit(EmojiDownloadStatus.failed);
    await tester.pumpAndSettle();
    await tester.tap(find.text('重试下载'));
    await tester.pump();
    expect(manager.starts, 2);
    manager.emit(EmojiDownloadStatus.installing);
    await tester.pump();
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('预览失败可以重试，下载功能关闭有解释', (tester) async {
    final catalog = _Catalog()..fail = true, store = _Store();
    final manager = _Manager(store, catalog,
        flags: const EmojiFeatureFlags(officialPackDownload: false));
    await setGoldenViewport(tester, GoldenViewports.phone360x800);
    await tester.pumpWidget(GoldenTestApp(
        home: EmojiPackPreviewScreen(
            entry: entry, catalog: catalog, manager: manager)));
    await tester.pumpAndSettle();
    expect(find.text('预览加载失败'), findsOneWidget);
    catalog.fail = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('这个表情包还没有内容'), findsOneWidget);
    expect(find.text('官方下载暂未开放，已有表情仍可使用。'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull);
  });
  testWidgets('切号后旧预览与动作失效，包括 A → B → A', (tester) async {
    final recent = EmojiRecentManager(
        preferencesLoader: () async => MemoryPreferencesStore())
      ..switchUser('A');
    final catalog = _Catalog(), manager = _Manager(_Store(), _Catalog());
    await tester.pumpWidget(GoldenTestApp(
        home: EmojiPackPreviewScreen(
            entry: entry,
            catalog: catalog,
            manager: manager,
            recentManager: recent)));
    await tester.pumpAndSettle();
    recent.switchUser('B');
    recent.switchUser('A');
    await tester.pumpAndSettle();
    expect(find.text('账号已切换，请返回'), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
    expect(find.text('测试官方包'), findsNothing);
  });
  testWidgets('下载预览在 320px 深色 1.5 倍字号不溢出，主操作命中区 >=44', (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final catalog = _Catalog(), manager = _Manager(_Store(), _Catalog());
    await tester.pumpWidget(GoldenTestApp(
        themeMode: ThemeMode.dark,
        textScaler: const TextScaler.linear(1.5),
        home: EmojiPackPreviewScreen(
            entry: entry,
            catalog: catalog,
            manager: manager,
            installation: installation.copyWith(
                status: EmojiPackInstallStatus.damaged))));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(FilledButton)).height,
        greaterThanOrEqualTo(44));
    await setGoldenViewport(tester, GoldenViewports.phone360x800);
  });
}
