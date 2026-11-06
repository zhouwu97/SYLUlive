import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shenliyuan/features/emoji/application/emoji_recent_manager.dart';
import 'package:shenliyuan/features/emoji/data/emoji_pack_runtime.dart';
import 'package:shenliyuan/features/emoji/domain/emoji_pack.dart';
import 'package:shenliyuan/features/emoji/domain/emoji_pack_installation.dart';
import 'package:shenliyuan/features/emoji/domain/emoji_pack_manifest.dart';
import 'package:shenliyuan/features/emoji/presentation/emoji_local_thumbnail.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/services/emoji_favorite_service.dart';
import 'package:shenliyuan/widgets/emoji/app_emoji_panel.dart';

import '../../helpers/emoji_flow_qa.dart';
import '../../helpers/golden_test_app.dart';
import '../../helpers/golden_viewport.dart';

class _TestPaths extends PathProviderPlatform {
  _TestPaths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

void main() {
  setUpAll(loadEmojiQAFonts);
  for (final groupId in ['mingfeng-ovo', 'mingfengfeng', 'mingfeng']) {
    for (final dark in [false, true]) {
      testWidgets('官方面板的图片、名称和发送文件对应 $groupId dark=$dark', (tester) async {
        await setGoldenViewport(tester, GoldenViewports.phone360x800);
        final account = 'official-panel-qa-$groupId-$dark';
        final oldPaths = PathProviderPlatform.instance;
        late Directory root;
        final pack = await tester.runAsync(() async {
          root = await Directory.systemTemp.createTemp('emoji-official-panel-');
          PathProviderPlatform.instance = _TestPaths(root.path);
          final store = await EmojiPackRuntime.forAccount(account);
          final groups = jsonDecode(await File(
                  '../server/internal/handlers/sticker_assets/catalog.json')
              .readAsString()) as List;
          final group = groups.singleWhere((item) => item['id'] == groupId);
          final assets = <EmojiManifestAsset>[];
          for (final item in group['items'] as List) {
            final source = File(
                '../server/internal/handlers/sticker_assets/${item['file']}');
            final bytes = await source.readAsBytes();
            assets.add(EmojiManifestAsset(
                id: item['id'],
                path: item['file'],
                name: item['label'],
                sha256: sha256.convert(bytes).toString(),
                mimeType: item['mime_type'],
                fileSize: bytes.length,
                animated: item['mime_type'] == 'image/gif'));
            final installedFile = File(
                '${store.versionDirectory(groupId, group['version']).path}/${item['file']}');
            await installedFile.parent.create(recursive: true);
            await installedFile.writeAsBytes(bytes);
          }
          final manifest = EmojiPackManifest(
              schemaVersion: 1,
              packId: group['id'],
              version: group['version'],
              totalSize: assets.fold(0, (sum, a) => sum + a.fileSize),
              assets: assets);
          final installation = EmojiPackInstallation(
              manifest: manifest,
              manifestSha256: group['content_sha256'],
              name: group['name'],
              trustLevel: EmojiPackTrustLevel.serverOfficial);
          await store.exclusive(() => store.commit(installation));
          return installation;
        });
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          PaintingBinding.instance.imageCache.clear();
          PaintingBinding.instance.imageCache.clearLiveImages();
          PathProviderPlatform.instance = oldPaths;
          await tester.runAsync(() => root.delete(recursive: true));
        });
        final preferences = MemoryPreferencesStore();
        final recent =
            EmojiRecentManager(preferencesLoader: () async => preferences)
              ..switchUser(account);
        String? selectedKey;
        String? selectedPath;
        final screenshot = GlobalKey();
        await tester.pumpWidget(GoldenTestApp(
            themeMode: dark ? ThemeMode.dark : ThemeMode.light,
            textScaler: TextScaler.linear(dark ? 1.3 : 1),
            home: Scaffold(
                body: RepaintBoundary(
                    key: screenshot,
                    child: SizedBox(
                        height: 520,
                        child: AppEmojiPanel(
                            recentManager: recent,
                            favoriteService: EmojiFavoriteService(
                                preferencesLoader: () async => preferences),
                            onEmojiSelected: (_) {},
                            onBackspace: () {},
                            onPackAssetSelected: (path, asset) {
                              selectedPath = path;
                              selectedKey = asset.assetKey;
                            }))))));
        final tab = find.byKey(ValueKey('installed-pack-$groupId'));
        for (var i = 0; i < 300 && tab.evaluate().isEmpty; i++) {
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)));
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(tab, findsOneWidget);
        await tester.ensureVisible(tab);
        await tester.tap(tab);
        await tester.pumpAndSettle();
        await captureEmojiQA(
            tester, screenshot, 'official-$groupId-${dark ? 'dark' : 'light'}');
        final search = find.byKey(ValueKey('emoji-search-$groupId'));
        for (final asset in pack!.manifest.assets) {
          await tester.enterText(search, asset.name);
          await tester.pumpAndSettle();
          final cell = find.bySemanticsLabel(asset.name);
          expect(cell, findsOneWidget, reason: asset.name);
          expect(find.descendant(of: cell, matching: find.text(asset.name)),
              findsOneWidget,
              reason: '每张表情都应显示对应文字');
          final image = tester.widget<Image>(
              find.descendant(of: cell, matching: find.byType(Image)).first);
          if (groupId == 'mingfeng-ovo') {
            expect((image.image as AssetImage).assetName,
                'assets/images/stickers/mingfeng-ovo/${asset.id}.png');
          } else {
            expect((image.image as EmojiLocalThumbnail).source.path,
                endsWith('/${asset.path}'));
          }
          if (asset.name == '撒') {
            FocusManager.instance.primaryFocus?.unfocus();
            await tester.pump();
            await captureEmojiQA(
                tester,
                screenshot,
                dark
                    ? 'official-sprinkle-search-dark'
                    : 'official-sprinkle-search');
          }
          await tester.tap(cell);
          expect(selectedKey, 'official:$groupId:${asset.id}');
          expect(selectedPath, endsWith('/${asset.path}'));
        }
        expect(tester.takeException(), isNull);
      });
    }
  }
}
