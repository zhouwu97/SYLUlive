import 'dart:io';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../data/emoji_pack_catalog_repository.dart';
import '../data/emoji_pack_local_store.dart';
import '../domain/emoji_feature_flags.dart';
import '../domain/emoji_pack.dart';
import '../domain/emoji_pack_limits.dart';
import 'emoji_pack_installer.dart';

enum EmojiDownloadStatus { downloading, installing, paused, failed, installed }

class EmojiDownloadTask {
  EmojiDownloadTask(this.entry, this.status,
      {this.receivedBytes = 0, this.error});
  final EmojiCatalogEntry entry;
  EmojiDownloadStatus status;
  int receivedBytes;
  String? error;
  Map<String, dynamic> toJson() => {
        'entry': entry.toJson(),
        'status': status.name,
        'received_bytes': receivedBytes,
        'error': error
      };
}

class EmojiPackDownloadManager extends ChangeNotifier {
  static final _shared = Expando<EmojiPackDownloadManager>();
  static EmojiPackDownloadManager shared(
          EmojiPackLocalStore store, EmojiPackCatalogRepository catalog) =>
      _shared[store] ??= EmojiPackDownloadManager(store, catalog);
  EmojiPackDownloadManager(this.store, this.catalog,
      {this.flags = EmojiFeatureFlags.production});
  final EmojiPackLocalStore store;
  final EmojiPackCatalogRepository catalog;
  final EmojiFeatureFlags flags;
  final tasks = <String, EmojiDownloadTask>{};
  final _tokens = <String, CancelToken>{};
  Future<void> restore() async {
    final downloads = await store.exclusive(() async {
      final index = await store.readIndex();
      final records = index['downloads'] as Map;
      final restored = <EmojiDownloadTask>[];
      var changed = false;
      for (final raw in records.entries.toList()) {
        try {
          final json = Map<String, dynamic>.from(raw.value as Map);
          final entry = EmojiCatalogEntry.fromJson(
              Map<String, dynamic>.from(json['entry'] as Map));
          if (entry.id != raw.key || _tokens.containsKey(entry.id)) {
            continue;
          }
          final savedStatus = json['status'] as String? ?? '';
          final status = switch (savedStatus) {
            'downloading' || 'installing' => EmojiDownloadStatus.paused,
            'paused' => EmojiDownloadStatus.paused,
            'failed' => EmojiDownloadStatus.failed,
            'installed' => EmojiDownloadStatus.installed,
            _ => null,
          };
          if (status == null) {
            records.remove(raw.key);
            changed = true;
            continue;
          }
          restored.add(EmojiDownloadTask(entry, status,
              receivedBytes: json['received_bytes'] as int? ?? 0,
              error: json['error'] as String?));
          if (savedStatus == 'downloading' || savedStatus == 'installing') {
            records[raw.key] = restored.last.toJson();
            changed = true;
          }
        } catch (_) {
          records.remove(raw.key);
          changed = true;
        }
      }
      if (changed) await store.writeIndex(index);
      return restored;
    });
    tasks.removeWhere((id, _) => !_tokens.containsKey(id));
    for (final task in downloads) {
      if (_tokens.containsKey(task.entry.id)) continue;
      tasks[task.entry.id] = task;
    }
    notifyListeners();
  }

  Future<void> _persist(EmojiDownloadTask task) => store.exclusive(() async {
        final index = await store.readIndex();
        final downloads =
            index.putIfAbsent('downloads', () => <String, dynamic>{}) as Map;
        downloads[task.entry.id] = task.toJson();
        await store.writeIndex(index);
      });
  void pause(String packId) {
    if (tasks[packId]?.status != EmojiDownloadStatus.downloading) return;
    _tokens[packId]?.cancel('已暂停');
  }

  Future<void> start(EmojiCatalogEntry entry) async {
    if (!flags.officialPackDownload) throw StateError('官方下载尚未开放');
    if (_tokens.containsKey(entry.id)) return;
    final task = tasks[entry.id] =
        EmojiDownloadTask(entry, EmojiDownloadStatus.downloading);
    final token = _tokens[entry.id] = CancelToken();
    notifyListeners();
    try {
      await _persist(task);
      final manifest = await catalog.manifest(entry, token);
      if (manifest.totalSize > EmojiPackLimits.maxExpandedBytes ||
          manifest.assets.length > EmojiPackLimits.maxAssetCount) {
        throw const FormatException('官方包超出资源限制');
      }
      final directory = Directory(
          '${store.root.path}/downloads/${store.directoryKey(entry.id)}/${entry.version}');
      await directory.create(recursive: true);
      final files = <String, File>{};
      for (final asset in manifest.assets) {
        if (token.isCancelled) throw token.cancelError!;
        if (asset.fileSize > EmojiPackLimits.maxSingleAssetBytes) {
          throw const FormatException('图片超出大小限制');
        }
        final file = File(
            '${directory.path}/${sha256.convert(utf8.encode(asset.id))}.part');
        var offset = await file.exists() ? await file.length() : 0;
        if (offset > asset.fileSize) {
          await file.delete();
          offset = 0;
        }
        if (offset < asset.fileSize) {
          final response = await catalog.dio.get<ResponseBody>(
              '/emoji/packs/${entry.id}/assets/${Uri.encodeComponent(asset.id)}',
              queryParameters: {'version': entry.version},
              cancelToken: token,
              options: Options(
                  responseType: ResponseType.stream,
                  followRedirects: false,
                  headers: offset == 0
                      ? {}
                      : {
                          'Range': 'bytes=$offset-',
                          'If-Range': '"${asset.sha256}"'
                        }));
          if (response.statusCode == 206) {
            final range = response.headers.value('content-range');
            if (range == null ||
                !range.startsWith('bytes $offset-') ||
                !range.endsWith('/${asset.fileSize}')) {
              throw const FormatException('续传范围不匹配');
            }
          } else if (response.statusCode == 200) {
            offset = 0;
          } else {
            throw const FormatException('资源响应状态无效');
          }
          task.receivedBytes += offset;
          final sink = file.openWrite(
              mode: offset == 0 ? FileMode.write : FileMode.append);
          var received = offset;
          try {
            await for (final chunk in response.data!.stream) {
              if (token.isCancelled) throw token.cancelError!;
              received += chunk.length;
              if (received > asset.fileSize) {
                throw const FormatException('资源响应超出大小');
              }
              sink.add(chunk);
              task.receivedBytes += chunk.length;
              notifyListeners();
            }
          } finally {
            await sink.flush();
            await sink.close();
          }
        } else {
          task.receivedBytes += offset;
        }
        if (await file.length() != asset.fileSize ||
            (await sha256.bind(file.openRead()).first).toString() !=
                asset.sha256.toLowerCase()) {
          await file.delete();
          throw const FormatException('下载资源校验失败，请重试');
        }
        files[asset.path] = file;
      }
      if (token.isCancelled) throw token.cancelError!;
      task.status = EmojiDownloadStatus.installing;
      task.error = null;
      notifyListeners();
      await _persist(task);
      await EmojiPackInstaller(store).install(
          manifest: manifest,
          name: entry.name,
          trustLevel: EmojiPackTrustLevel.serverOfficial,
          expectedManifestSha256: entry.manifestSha256,
          readAsset: (asset) => files[asset.path]!.readAsBytes());
      task.status = EmojiDownloadStatus.installed;
      task.receivedBytes = entry.totalSize;
      try {
        await directory.delete(recursive: true);
      } on FileSystemException catch (error) {
        debugPrint('表情下载缓存清理失败: $error');
      }
    } catch (error) {
      debugPrint('表情包下载失败: $error');
      task.status = token.isCancelled
          ? EmojiDownloadStatus.paused
          : EmojiDownloadStatus.failed;
      task.error = token.isCancelled ? null : '下载或校验失败，请重试';
    } finally {
      _tokens.remove(entry.id);
      await _persist(task);
      notifyListeners();
    }
  }
}
