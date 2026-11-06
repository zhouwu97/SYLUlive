import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/services.dart';
import 'package:crypto/crypto.dart';
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
import 'package:shenliyuan/features/emoji/presentation/emoji_ui.dart';
import 'package:shenliyuan/widgets/emoji/sticker_catalog.dart';
import 'package:shenliyuan/features/emoji/application/emoji_pack_installer.dart';
import '../../helpers/emoji_flow_qa.dart';
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

class _PreviewCatalog extends _Catalog {
  _PreviewCatalog(this.previewManifest);
  final EmojiPackManifest previewManifest;
  @override
  Future<EmojiPackManifest> manifest(EmojiCatalogEntry entry, CancelToken token) async =>
      previewManifest;
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
  setUpAll(loadEmojiQAFonts);
  for (final official in [true, false]) {
    testWidgets('商城按资源身份选择动图预览 official=$official', (tester) async {
      const asset = EmojiManifestAsset(
          id: '4093d7cdb944076e0a8e4e06be2e2776',
          path: 'assets/4093d7cdb944076e0a8e4e06be2e2776.gif', name: '撒',
          sha256: '7b9c938279d0f9ddc716cf6e458dfe2ccf92aead43a1277f842db6dc2502794a',
          mimeType: 'image/gif', fileSize: 634590, animated: true);
      const manifest = EmojiPackManifest(schemaVersion: 1, packId: 'mingfeng-ovo',
          version: 2026072901, totalSize: 634590, assets: [asset]);
      final item = EmojiCatalogEntry(id: manifest.packId, name: '明风 OvO',
          version: manifest.version, assetCount: 1, totalSize: manifest.totalSize,
          manifestSha256: 'test', source: official ? 'official' : 'community');
      final catalog = _PreviewCatalog(manifest);
      final manager = _Manager(_Store(), catalog);
      await tester.pumpWidget(GoldenTestApp(home: EmojiPackPreviewScreen(
          entry: item, catalog: catalog, manager: manager)));
      await tester.pumpAndSettle();
      final grid = tester.widget<EmojiPreviewGrid>(find.byType(EmojiPreviewGrid));
      expect(grid.items.single.name, '撒');
      expect(grid.items.single.previewImage, isA<NetworkImage>());
      if (official) {
        expect((grid.items.single.image as AssetImage).assetName,
            'assets/images/stickers/mingfeng-ovo/${asset.id}.png');
      } else {
        expect(grid.items.single.image, isA<NetworkImage>());
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
  for (final profile in ['light', 'dark', 'large', 'stress']) {
    testWidgets('免费商城封面、作者与静态预览真实渲染 $profile', (tester) async {
      await setGoldenViewport(tester, GoldenViewports.phone360x800);
      late Directory root;
      late _CommunityCatalog catalog;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('emoji-store-render-');
        catalog = await _CommunityCatalog.create();
        final source = appStickerGroups.first.items.take(4).toList();
        for (var i = 0; i < source.length; i++) {
          final bytes = (await rootBundle.load(source[i].thumbnailAsset))
              .buffer
              .asUint8List();
          final urls = [
            'https://example.test/api/emoji/packs/${_CommunityCatalog.id}/assets/image-${i + 1}?version=1&variant=thumbnail',
            'https://example.test/api/emoji/packs/${_CommunityCatalog.id}/assets/image-${i + 1}?version=1',
            if (i == 0)
              'https://example.test/api/emoji/packs/${_CommunityCatalog.id}/cover?version=1',
          ];
          for (final url in urls) {
            final codec = await ui.instantiateImageCodec(bytes);
            final frame = await codec.getNextFrame();
            codec.dispose();
            PaintingBinding.instance.imageCache.putIfAbsent(
                NetworkImage(url),
                () => OneFrameImageStreamCompleter(
                    Future.value(ImageInfo(image: frame.image))));
          }
        }
      });
      addTearDown(() => root.delete(recursive: true));
      final key = GlobalKey();
      await tester.pumpWidget(RepaintBoundary(
          key: key,
          child: GoldenTestApp(
              themeMode: profile == 'dark' ? ThemeMode.dark : ThemeMode.light,
              textScaler: TextScaler.linear(profile == 'stress'
                  ? 1.5
                  : profile == 'large'
                      ? 1.3
                      : 1),
              home: EmojiDownloadScreen(
                  store: EmojiPackLocalStore(root), repository: catalog))));
      await waitForEmojiWork(tester);
      expect(find.text('表情商城'), findsOneWidget);
      expect(find.textContaining('测试创作者'), findsOneWidget);
      await captureEmojiQA(tester, key, 'store-$profile');
      await tester.tap(find.text('校园反应'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(FilledButton, '免费下载并添加'), findsOneWidget);
      await captureEmojiQA(tester, key, 'store-detail-$profile');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
    });
  }
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

class _CommunityCatalog extends EmojiPackCatalogRepository {
  _CommunityCatalog(this.data)
      : super(Dio(BaseOptions(baseUrl: 'https://example.test/api')));
  static const id = 'community-00000000-0000-0000-0000-000000000001';
  final EmojiPackManifest data;
  static Future<_CommunityCatalog> create() async {
    final assets = <EmojiManifestAsset>[];
    for (final sticker in appStickerGroups.first.items.take(4)) {
      final bytes =
          (await rootBundle.load(sticker.thumbnailAsset)).buffer.asUint8List();
      final id = 'image-${assets.length + 1}';
      assets.add(EmojiManifestAsset(
          id: id,
          path: 'assets/$id.png',
          name: sticker.label,
          sha256: sha256.convert(bytes).toString(),
          mimeType: 'image/png',
          fileSize: bytes.length));
    }
    return _CommunityCatalog(EmojiPackManifest(
        schemaVersion: 1,
        packId: id,
        version: 1,
        totalSize: assets.fold(0, (sum, asset) => sum + asset.fileSize),
        assets: assets));
  }

  late final item = EmojiCatalogEntry(
      id: id,
      name: '校园反应',
      version: 1,
      assetCount: 4,
      totalSize: data.totalSize,
      manifestSha256: EmojiPackInstaller.manifestHash(data),
      source: 'community',
      authorName: '测试创作者',
      tags: const ['日常', '校园'],
      mediaVersion: 1,
      coverAssetId: 'image-1',
      iconAssetId: 'image-1',
      previewAssetIds: const ['image-1', 'image-2', 'image-3', 'image-4']);
  @override
  Future<List<EmojiCatalogEntry>> list() async => [item];
  @override
  Future<EmojiPackManifest> manifest(
          EmojiCatalogEntry entry, CancelToken token) async =>
      data;
}
