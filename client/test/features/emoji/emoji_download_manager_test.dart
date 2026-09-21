import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:shenliyuan/features/emoji/application/emoji_pack_download_manager.dart';
import 'package:shenliyuan/features/emoji/application/emoji_pack_installer.dart';
import 'package:shenliyuan/features/emoji/data/emoji_pack_catalog_repository.dart';
import 'package:shenliyuan/features/emoji/data/emoji_pack_local_store.dart';
import 'package:shenliyuan/features/emoji/domain/emoji_pack_manifest.dart';

void main() {
  test('官方下载跨实例恢复断点，校验成功才安装', () async {
    final root = await Directory.systemTemp.createTemp('emoji-download-');
    addTearDown(() => root.delete(recursive: true));
    final bytes = image.encodePng(image.Image(width: 2, height: 2));
    final manifest = EmojiPackManifest(
        schemaVersion: 1,
        packId: 'test',
        version: 1,
        totalSize: bytes.length,
        assets: [
          EmojiManifestAsset(
              id: 'a',
              path: 'assets/a.png',
              name: 'a',
              sha256: sha256.convert(bytes).toString(),
              mimeType: 'image/png',
              fileSize: bytes.length)
        ]);
    final entry = EmojiCatalogEntry(
        id: 'test',
        name: '测试',
        version: 1,
        assetCount: 1,
        totalSize: bytes.length,
        manifestSha256: EmojiPackInstaller.manifestHash(manifest));
    final store = EmojiPackLocalStore(root);
    final dio = Dio(BaseOptions(baseUrl: 'https://example.test/api'));
    String? range;
    dio.interceptors.add(InterceptorsWrapper(onRequest: (request, handler) {
      if (request.path.endsWith('/manifest')) {
        handler.resolve(Response(
            requestOptions: request, statusCode: 200, data: manifest.toJson()));
      } else {
        range = request.headers['Range'] as String?;
        handler.resolve(Response(
            requestOptions: request,
            statusCode: 206,
            headers: Headers.fromMap({
              'content-range': ['bytes 10-${bytes.length - 1}/${bytes.length}']
            }),
            data: ResponseBody.fromBytes(bytes.sublist(10), 206, headers: {
              'content-range': ['bytes 10-${bytes.length - 1}/${bytes.length}']
            })));
      }
    }));
    final part = File(
        '${root.path}/downloads/${store.directoryKey('test')}/1/${sha256.convert(utf8.encode('a'))}.part');
    await part.parent.create(recursive: true);
    await part.writeAsBytes(bytes.take(10).toList());
    await store.exclusive(() async {
      await store.writeIndex({
        'packs': {},
        'tombstones': {},
        'downloads': {
          'test': {
            'entry': entry.toJson(),
            'status': 'downloading',
            'received_bytes': 10
          }
        }
      });
    });
    final manager =
        EmojiPackDownloadManager(store, EmojiPackCatalogRepository(dio));
    await manager.restore();
    expect(manager.tasks['test']!.status, EmojiDownloadStatus.paused);
    await manager.start(entry);
    expect(range, 'bytes=10-');
    expect(manager.tasks['test']!.status, EmojiDownloadStatus.installed);
    expect((await store.load()).single.version, 1);
  });

  test('网络失败保留可重试任务且不产生安装，拒绝非 HTTPS 官方目录', () async {
    final root =
        await Directory.systemTemp.createTemp('emoji-download-failed-');
    addTearDown(() => root.delete(recursive: true));
    final store = EmojiPackLocalStore(root);
    expect(
        () => EmojiPackCatalogRepository(
            Dio(BaseOptions(baseUrl: 'http://example.test'))),
        throwsArgumentError);
    final dio = Dio(BaseOptions(baseUrl: 'https://example.test'));
    dio.interceptors.add(InterceptorsWrapper(
        onRequest: (request, handler) =>
            handler.reject(DioException(requestOptions: request))));
    final manager =
        EmojiPackDownloadManager(store, EmojiPackCatalogRepository(dio));
    final entry = EmojiCatalogEntry(
        id: 'test',
        name: '测试',
        version: 1,
        assetCount: 1,
        totalSize: 10,
        manifestSha256: '0' * 64);
    await manager.start(entry);
    expect(manager.tasks['test']!.status, EmojiDownloadStatus.failed);
    expect(await store.load(), isEmpty);
    final restored =
        EmojiPackDownloadManager(store, EmojiPackCatalogRepository(dio));
    await restored.restore();
    expect(restored.tasks['test']!.status, EmojiDownloadStatus.failed);
  });
}
