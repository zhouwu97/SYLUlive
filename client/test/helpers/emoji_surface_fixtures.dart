import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:shenliyuan/features/emoji/data/emoji_pack_catalog_repository.dart';
import 'package:shenliyuan/features/emoji/data/emoji_pack_local_store.dart';
import 'package:shenliyuan/features/emoji/domain/emoji_pack_installation.dart';
import 'package:shenliyuan/features/emoji/domain/emoji_pack_manifest.dart';
import 'package:shenliyuan/features/emoji/application/emoji_recent_manager.dart';
import 'package:shenliyuan/features/emoji/presentation/emoji_download_screen.dart';
import 'package:shenliyuan/features/emoji/presentation/emoji_management_screen.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/services/emoji_favorite_service.dart';
import 'package:shenliyuan/widgets/emoji/app_emoji_panel.dart';
import 'package:shenliyuan/widgets/global_background_wrapper.dart';

class EmojiSurfaceStore extends EmojiPackLocalStore {
  EmojiSurfaceStore() : super(Directory.systemTemp);
  @override
  Future<Map<String, dynamic>> readIndex() async =>
      {'packs': {}, 'downloads': {}};
  @override
  Future<List<EmojiPackInstallation>> load() async => [];
}

class EmojiSurfaceCatalog extends EmojiPackCatalogRepository {
  EmojiSurfaceCatalog()
      : super(Dio(BaseOptions(baseUrl: 'https://fixture.test/api')));
  @override
  Future<List<EmojiCatalogEntry>> list() async => [
        const EmojiCatalogEntry(
            id: 'fixture',
            name: '本地官方表情',
            version: 1,
            assetCount: 0,
            totalSize: 100,
            manifestSha256: 'fixture')
      ];
  @override
  Future<EmojiPackManifest> manifest(
          EmojiCatalogEntry entry, CancelToken token) async =>
      const EmojiPackManifest(
          schemaVersion: 1,
          packId: 'fixture',
          version: 1,
          totalSize: 100,
          assets: []);
}

Widget emojiSurfaceScene(String scene) {
  final prefs = MemoryPreferencesStore();
  final favorites = EmojiFavoriteService(preferencesLoader: () async => prefs);
  final recent = EmojiRecentManager(preferencesLoader: () async => prefs);
  if (scene == 'official') {
    return EmojiDownloadScreen(
        store: EmojiSurfaceStore(),
        repository: EmojiSurfaceCatalog(),
        recentManager: recent);
  }
  if (scene == 'management') {
    return EmojiManagementScreen(
        store: EmojiSurfaceStore(),
        favoriteService: favorites,
        recentManager: recent);
  }
  return GlobalBackgroundWrapper(
      child: Scaffold(
          backgroundColor: Colors.transparent,
          body: Align(
              alignment: Alignment.bottomCenter,
              child: SizedBox(
                  height: 320,
                  child: AppEmojiPanel(
                      favoriteService: favorites,
                      recentManager: recent,
                      onEmojiSelected: (_) {},
                      onBackspace: () {})))));
}
