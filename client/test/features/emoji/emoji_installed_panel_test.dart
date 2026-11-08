import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shenliyuan/features/emoji/application/emoji_pack_importer.dart';
import 'package:shenliyuan/features/emoji/application/emoji_pack_installer.dart';
import 'package:shenliyuan/features/emoji/application/emoji_recent_manager.dart';
import 'package:shenliyuan/features/emoji/data/emoji_pack_runtime.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/services/emoji_favorite_service.dart';
import 'package:shenliyuan/widgets/emoji/app_emoji_panel.dart';
import 'package:shenliyuan/widgets/emoji/sticker_catalog.dart';

import '../../helpers/emoji_flow_qa.dart';
import '../../helpers/golden_test_app.dart';
import '../../helpers/golden_viewport.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

Future<void> _loaded(WidgetTester tester, Finder target) async {
  for (var frame = 0; frame < 300 && target.evaluate().isEmpty; frame++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(target, findsOneWidget);
  await tester.pump(const Duration(milliseconds: 350));
}

void main() {
  setUpAll(loadEmojiQAFonts);
  for (final dark in [false, true]) {
    testWidgets('安装包按对应文字筛选、空结果和切号隔离 dark=$dark', (tester) async {
      await setGoldenViewport(tester, GoldenViewports.phone360x800);
      final oldPaths = PathProviderPlatform.instance;
      late Directory root;
      final prefs = MemoryPreferencesStore();
      final recent = EmojiRecentManager(preferencesLoader: () async => prefs)
        ..switchUser('panel-$dark');
      final favorites =
          EmojiFavoriteService(preferencesLoader: () async => prefs);
      final pack = await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('emoji-panel-search-');
        PathProviderPlatform.instance = _Paths(root.path);
        final store = await EmojiPackRuntime.forAccount('panel-$dark');
        final files = <File>[];
        var index = 0;
        for (final sticker in appStickerGroups.first.items.take(2)) {
          final bytes = await rootBundle.load(sticker.thumbnailAsset);
          files.add(await File('${root.path}/${['收到', '开心'][index++]}.png')
              .writeAsBytes(bytes.buffer.asUint8List()));
        }
        final importer = EmojiPackImporter(EmojiPackInstaller(store));
        return importer.installPrepared(await importer.prepareImages(files));
      });
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        PaintingBinding.instance.imageCache.clear();
        PaintingBinding.instance.imageCache.clearLiveImages();
        PathProviderPlatform.instance = oldPaths;
        for (var attempt = 0;; attempt++) {
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 50)));
          await tester.pump();
          final deleted = await tester.runAsync(() async {
            try {
              await root.delete(recursive: true);
              return true;
            } on FileSystemException {
              return false;
            }
          });
          if (deleted == true) break;
          expect(attempt, lessThan(9), reason: '临时目录仍被图片或文件 IO 占用');
        }
      });
      String? selected;
      final screenshot = GlobalKey();
      await tester.pumpWidget(RepaintBoundary(
          key: screenshot,
          child: GoldenTestApp(
              themeMode: dark ? ThemeMode.dark : ThemeMode.light,
              textScaler: const TextScaler.linear(1.5),
              home: Scaffold(
                  body: SizedBox(
                      height: 330,
                      child: AppEmojiPanel(
                          recentManager: recent,
                          favoriteService: favorites,
                          onEmojiSelected: (_) {},
                          onBackspace: () {},
                          onPackAssetSelected: (path, asset) =>
                              selected = asset.assetKey))))));
      final tab = find.byKey(ValueKey('installed-pack-${pack!.packId}'));
      await _loaded(tester, tab);
      await tester.tap(tab);
      final search = find.byKey(ValueKey('emoji-search-${pack.packId}'));
      await _loaded(tester, search);
      expect(find.byKey(ValueKey('installed-pack-title-${pack.packId}')),
          findsOneWidget,
          reason: '内容、标题与当前包标签必须一致');
      await tester.enterText(search, '没有这张');
      await tester.pump();
      expect(find.text('没有找到对应表情，试试其他文字'), findsOneWidget);
      await tester.enterText(search, '收');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      expect(find.bySemanticsLabel('收到'), findsOneWidget);
      expect(find.bySemanticsLabel('开心'), findsNothing);
      await tester.tap(find.bySemanticsLabel('收到'));
      expect(selected, 'local:${pack.packId}:image-1');
      await captureEmojiQA(tester, screenshot,
          'installed-search-${dark ? 'dark' : 'light'}-stress');
      recent.switchUser('other-panel-$dark');
      await tester.pump();
      expect(search, findsNothing);
      expect(find.bySemanticsLabel('收到'), findsNothing);
      var accountOpened = false;
      EmojiPackRuntime.forAccount('other-panel-$dark')
          .then((_) => accountOpened = true);
      for (var frame = 0; frame < 200 && !accountOpened; frame++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(accountOpened, isTrue);
      expect(tester.takeException(), isNull);
    });
  }
}
