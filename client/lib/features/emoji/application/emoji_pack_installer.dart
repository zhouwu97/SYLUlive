import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as image;
import 'package:path/path.dart' as path;

import '../data/emoji_pack_local_store.dart';
import '../domain/emoji_pack.dart';
import '../domain/emoji_pack_installation.dart';
import '../domain/emoji_pack_limits.dart';
import '../domain/emoji_pack_manifest.dart';

class EmojiPackInstaller {
  EmojiPackInstaller(this.store, {this.checkpoint});
  final EmojiPackLocalStore store;

  /// 故障注入用于验证真实磁盘中断后的恢复，不参与生产状态决策。
  final Future<void> Function(String phase)? checkpoint;
  File get _journal => File('${store.root.path}/install-journal.json');
  Directory get _backup => Directory('${store.root.path}/install-backup');
  Directory get _staging => Directory('${store.root.path}/staging');

  static String manifestHash(EmojiPackManifest manifest) =>
      sha256.convert(canonicalManifestBytes(manifest)).toString();

  static List<int> canonicalManifestBytes(EmojiPackManifest manifest) {
    Object? sorted(Object? value) {
      if (value is Map) {
        final keys = value.keys.cast<String>().toList()..sort();
        return {for (final key in keys) key: sorted(value[key])};
      }
      if (value is List) return value.map(sorted).toList();
      return value;
    }

    return utf8.encode(jsonEncode(sorted(manifest.toJson())));
  }

  Future<void> recover() => store.exclusive(_recover);

  Future<void> _recover() async {
    if (await _journal.exists()) {
      final record = jsonDecode(await _journal.readAsString()) as Map;
      final installation = EmojiPackInstallation.fromJson(
          Map<String, dynamic>.from(record['installation'] as Map));
      final index = await store.readIndex();
      final committed = (index['packs'] as Map)[installation.packId];
      final isCommitted = committed is Map &&
          committed['manifest_sha256'] == installation.manifestSha256 &&
          committed['status'] == EmojiPackInstallStatus.installed.name;
      final destination =
          store.versionDirectory(installation.packId, installation.version);
      if (!isCommitted) {
        if (await _backup.exists()) {
          if (await destination.exists()) {
            await destination.delete(recursive: true);
          }
          await _backup.rename(destination.path);
        } else if (record['destination_existed'] != true &&
            await destination.exists()) {
          await destination.delete(recursive: true);
        }
      }
      if (await _backup.exists()) await _backup.delete(recursive: true);
      await _journal.delete();
    }
    if (await _staging.exists()) await _staging.delete(recursive: true);
  }

  /// 回滚跟着索引里的安装历史走。版本数值来自内容哈希或包作者自报，
  /// 大小关系不代表发布先后，所以这里不扫描「数值更小」的目录。
  ///
  /// 切换前先完整校验上一版目录（Manifest 身份 + 每个资源哈希），任一不符就抛错，
  /// 保持当前可用包不动；老索引没有历史指针时同样不猜测，让用户重新下载。
  Future<EmojiPackInstallation> rollback(String packId) async {
    final current = (await store.load()).where((p) => p.packId == packId).first;
    final previous = current.previous;
    if (previous == null) {
      throw StateError('没有记录上一版，请重新下载官方版本');
    }
    final directory = store.versionDirectory(packId, previous.version);
    final savedManifest = File('${directory.path}/manifest.json');
    if (!await savedManifest.exists()) {
      throw StateError('上一版目录已缺失，请重新下载官方版本');
    }
    final manifestBytes = await savedManifest.readAsBytes();
    final manifest = EmojiPackManifest.fromJson(Map<String, dynamic>.from(
        jsonDecode(utf8.decode(manifestBytes)) as Map));
    if (manifest.packId != packId ||
        manifest.version != previous.version ||
        sha256.convert(manifestBytes).toString() !=
            previous.manifestSha256) {
      throw StateError('上一版内容身份校验失败，请重新下载官方版本');
    }
    for (final asset in manifest.assets) {
      final file = File('${directory.path}/${asset.path}');
      if (!await file.exists() ||
          (await sha256.bind(file.openRead()).first).toString() !=
              asset.sha256.toLowerCase()) {
        throw StateError('上一版资源已损坏，请重新下载官方版本');
      }
    }
    return install(
        manifest: manifest,
        name: current.name,
        trustLevel: current.trustLevel,
        readAsset: (asset) =>
            File('${directory.path}/${asset.path}').readAsBytes());
  }

  Future<EmojiPackInstallation> install({
    required EmojiPackManifest manifest,
    required String name,
    required EmojiPackTrustLevel trustLevel,
    required Future<Uint8List> Function(EmojiManifestAsset asset) readAsset,
    String? expectedManifestSha256,
    String? externalPackId,
    String? importSourceSha256,
  }) =>
      store.exclusive(() async {
        await _recover();
        manifest.validate();
        if (manifest.assets.isEmpty ||
            manifest.assets.length > EmojiPackLimits.maxAssetCount ||
            manifest.totalSize > EmojiPackLimits.maxExpandedBytes) {
          throw const FormatException('表情包数量或大小超出限制');
        }
        final hash = manifestHash(manifest);
        if (expectedManifestSha256 != null &&
            hash != expectedManifestSha256.toLowerCase()) {
          throw const FormatException('Manifest 校验失败');
        }
        final index = await store.readIndex();
        final oldJson = (index['packs'] as Map)[manifest.packId];
        final old = oldJson == null
            ? null
            : EmojiPackInstallation.fromJson(
                Map<String, dynamic>.from(oldJson as Map));
        final destination =
            store.versionDirectory(manifest.packId, manifest.version);
        if (old != null && old.version == manifest.version) {
          if (old.manifestSha256 != hash) throw StateError('同版本表情包内容不可修改');
          if (await destination.exists()) {
            var valid = true;
            for (final asset in manifest.assets) {
              final file = File('${destination.path}/${asset.path}');
              if (!await file.exists() ||
                  (await sha256.bind(file.openRead()).first).toString() !=
                      asset.sha256.toLowerCase()) {
                valid = false;
                break;
              }
            }
            if (valid) return old;
            await store
                .commit(old.copyWith(status: EmojiPackInstallStatus.damaged));
            await destination.delete(recursive: true);
          } else {
            await store
                .commit(old.copyWith(status: EmojiPackInstallStatus.damaged));
          }
        }
        if (await destination.exists()) {
          final saved = File('${destination.path}/manifest.json');
          if (!await saved.exists() ||
              sha256.convert(await saved.readAsBytes()).toString() != hash) {
            throw StateError('同版本表情包内容不可修改');
          }
          // 已保留的回滚版本也重新校验资源，再更新活动索引。
        }
        final installation = EmojiPackInstallation(
            manifest: manifest,
            manifestSha256: hash,
            name: name,
            trustLevel: trustLevel,
            enabled: old?.enabled ?? true,
            sortOrder: old?.sortOrder ?? (index['packs'] as Map).length,
            externalPackId: externalPackId ?? old?.externalPackId,
            importSourceSha256: importSourceSha256 ?? old?.importSourceSha256);
        await _staging.create(recursive: true);
        try {
          for (final asset in manifest.assets) {
            if (asset.fileSize > EmojiPackLimits.maxSingleAssetBytes) {
              throw const FormatException('单张资源过大');
            }
            final bytes = await readAsset(asset);
            await compute(_validateImage, (asset, bytes));
            final file = File('${_staging.path}/${asset.path}');
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes, flush: true);
          }
          await File('${_staging.path}/manifest.json')
              .writeAsBytes(canonicalManifestBytes(manifest), flush: true);
          final journalTemporary = File('${_journal.path}.tmp');
          await journalTemporary.writeAsString(
              jsonEncode({
                'installation': installation.toJson(),
                'destination_existed': await destination.exists()
              }),
              flush: true);
          await journalTemporary.rename(_journal.path);
          await checkpoint?.call('beforeRename');
          await destination.parent.create(recursive: true);
          // 保留目标版本，恢复依据 Journal 决定还原或清理。
          if (await destination.exists()) {
            await destination.rename(_backup.path);
          }
          await _staging.rename(destination.path);
          await checkpoint?.call('beforeIndex');
          final persisted = await store.commit(installation);
          await checkpoint?.call('afterIndex');
          if (await _backup.exists()) await _backup.delete(recursive: true);
          await _journal.delete();
          if (await _staging.exists()) await _staging.delete(recursive: true);
          // 清理只跟着历史指针：保留当前版和上一版这两份目录，
          // 不按版本数值或哈希大小决定谁是「更早」。
          final keep = <String>{
            '${persisted.version}',
            if (persisted.previous != null) '${persisted.previous!.version}',
          };
          await for (final entity in destination.parent.list()) {
            if (entity is Directory &&
                !keep.contains(path.basename(entity.path))) {
              await entity.delete(recursive: true);
            }
          }
          return persisted;
        } catch (_) {
          await _recover();
          final recovered = (await store.readIndex())['packs'] as Map;
          final active = recovered[installation.packId];
          if (active is Map &&
              active['manifest_sha256'] == installation.manifestSha256 &&
              active['status'] == EmojiPackInstallStatus.installed.name) {
            // 索引已经切换成功，只是收尾被打断；返回磁盘上那份记录（含历史指针）。
            return EmojiPackInstallation.fromJson(
                Map<String, dynamic>.from(active));
          }
          rethrow;
        }
      });
}

void _validateImage((EmojiManifestAsset, Uint8List) input) {
  final (asset, bytes) = input;
  if (bytes.length != asset.fileSize ||
      bytes.length > EmojiPackLimits.maxSingleAssetBytes ||
      sha256.convert(bytes).toString() != asset.sha256.toLowerCase()) {
    throw const FormatException('资源大小或 Hash 校验失败');
  }
  final image.Decoder decoder = switch (asset.mimeType) {
    'image/png' => image.PngDecoder(),
    'image/jpeg' => image.JpegDecoder(),
    'image/gif' => image.GifDecoder(),
    _ => throw const FormatException('不支持的图片类型'),
  };
  if (!decoder.isValidFile(bytes)) throw const FormatException('图片 MIME 不匹配');
  final info = decoder.startDecode(bytes);
  if (info == null) throw const FormatException('图片无法解码');
  final limit = info.numFrames > 1
      ? EmojiPackLimits.maxAnimatedDimension
      : EmojiPackLimits.maxStaticDimension;
  if (info.width <= 0 ||
      info.height <= 0 ||
      info.width > limit ||
      info.height > limit ||
      info.numFrames < 1 ||
      info.numFrames > EmojiPackLimits.maxGifFrames ||
      info.width * info.height * info.numFrames >
          EmojiPackLimits.maxDecodedPixels ||
      (asset.width != null && asset.width != info.width) ||
      (asset.height != null && asset.height != info.height) ||
      asset.animated != (info.numFrames > 1)) {
    throw const FormatException('图片尺寸或帧数不符合约束');
  }
  for (var frame = 0; frame < info.numFrames; frame++) {
    if (decoder.decodeFrame(frame) == null) {
      throw const FormatException('图片帧损坏');
    }
  }
}
