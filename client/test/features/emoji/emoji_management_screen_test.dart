import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/emoji/data/emoji_pack_local_store.dart';
import 'package:shenliyuan/features/emoji/domain/emoji_pack.dart';
import 'package:shenliyuan/features/emoji/domain/emoji_pack_installation.dart';
import 'package:shenliyuan/features/emoji/domain/emoji_pack_manifest.dart';
import 'package:shenliyuan/features/emoji/presentation/emoji_management_screen.dart';
import 'package:shenliyuan/features/emoji/application/emoji_recent_manager.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/services/emoji_favorite_service.dart';
import 'package:shenliyuan/services/emoji_favorite_repository.dart';
import 'package:shenliyuan/widgets/emoji/sticker_catalog.dart';
import '../../helpers/golden_viewport.dart';
import '../../helpers/golden_test_app.dart';

class _SyncFavorites extends EmojiFavoriteRepository {
  _SyncFavorites() : super(Dio());
  bool fail = true;
  @override
  Future<EmojiFavoritePage> fetchFavorites() async => const EmojiFavoritePage(
      items: [], quotaUsed: 0, quotaLimit: 1000, favoriteLimit: 80);
  @override
  Future<EmojiFavoriteItem> createBuiltin(String stickerId) async {
    if (fail) {
      throw const EmojiFavoriteException(message: '收藏上传暂未完成');
    }
    return EmojiFavoriteItem.fromApiJson(
        {'id': 5, 'kind': 'builtin', 'sticker_id': stickerId});
  }
}

class _MemoryPackStore extends EmojiPackLocalStore {
  _MemoryPackStore() : super(Directory.systemTemp);
  List<EmojiPackInstallation> items = [
    const EmojiPackInstallation(
        manifest: EmojiPackManifest(
            schemaVersion: 1,
            packId: 'pack',
            version: 1,
            totalSize: 0,
            assets: []),
        manifestSha256: 'abc',
        name: '测试表情包',
        trustLevel: EmojiPackTrustLevel.localUntrusted)
  ];
  @override
  Future<List<EmojiPackInstallation>> load() async => items;
  @override
  Future<void> setEnabled(String packId, bool enabled) async {
    items = items.map((e) => e.copyWith(enabled: enabled)).toList();
  }

  @override
  Future<void> remove(String packId) async {
    items = [];
  }
}

void main() {
  testWidgets('收藏选择移除与撤销保留真实条目', (tester) async {
    final prefs = MemoryPreferencesStore();
    final service = EmojiFavoriteService(preferencesLoader: () async => prefs);
    final sticker = appStickerGroups.first.items.first;
    await service.toggleSticker(sticker.id);
    await tester.pumpWidget(MaterialApp(
        home: EmojiManagementScreen(
            store: _MemoryPackStore(),
            favoriteService: service,
            recentManager:
                EmojiRecentManager(preferencesLoader: () async => prefs))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('收藏'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择'));
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(ValueKey('managed-favorite-sticker:${sticker.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('移除已选收藏（1）'));
    await tester.pumpAndSettle();
    expect(await service.load(), isEmpty);
    expect(find.text('暂无收藏的表情'), findsOneWidget);
    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();
    expect((await service.load()).single.stickerId, sticker.id);
    expect(tester.takeException(), isNull);
  });
  for (final dark in [false, true]) {
    testWidgets('收藏上传失败保留内容，重试成功后恢复 dark=$dark', (tester) async {
      await setGoldenViewport(tester, GoldenViewports.phone360x800);
      final prefs = MemoryPreferencesStore(), repository = _SyncFavorites();
      final sticker = appStickerGroups.first.items.first;
      await prefs.setBool('emoji_favorites_v1_migrated_8', true);
      await prefs.setString(
          'emoji_favorites_cache_v2_8',
          jsonEncode([
            {'type': 'sticker', 'sticker_id': sticker.id}
          ]));
      final service = EmojiFavoriteService(
          userId: '8',
          repository: repository,
          preferencesLoader: () async => prefs);
      await service.load();
      await tester.pumpWidget(GoldenTestApp(
          themeMode: dark ? ThemeMode.dark : ThemeMode.light,
          textScaler: const TextScaler.linear(1.3),
          home: EmojiManagementScreen(
              store: _MemoryPackStore(),
              favoriteService: service,
              recentManager:
                  EmojiRecentManager(preferencesLoader: () async => prefs)
                    ..switchUser('8'))));
      await tester.pumpAndSettle();
      await tester.tap(find.text('收藏'));
      await tester.pumpAndSettle();
      expect(find.text('收藏上传暂未完成'), findsOneWidget);
      expect(find.byKey(ValueKey('managed-favorite-sticker:${sticker.id}')),
          findsOneWidget);
      repository.fail = false;
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(find.text('收藏上传暂未完成'), findsNothing);
      expect((await service.load()).single.serverId, 5);
      expect(tester.takeException(), isNull);
    });
    testWidgets('管理页启用、删除、空状态和大字号 dark=$dark', (tester) async {
      await setGoldenViewport(tester, GoldenViewports.phone360x800);
      final store = _MemoryPackStore();
      await tester.pumpWidget(MaterialApp(
          theme: dark ? ThemeData.dark() : ThemeData.light(),
          home: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
              child: EmojiManagementScreen(store: store))));
      await tester.pumpAndSettle();
      expect(find.text('测试表情包'), findsOneWidget);
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
      await tester.tap(find.byTooltip('测试表情包更多操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除本地安装'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(find.text('暂无已安装的表情包'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
