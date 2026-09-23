import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../domain/emoji_pack_installation.dart';

/// 所有索引变更使用同一队列，保留备份以恢复 Windows 替换文件的中间状态。
class EmojiPackLocalStore {
  EmojiPackLocalStore(this.root);
  final Directory root;
  Future<void> _queue = Future.value();
  File get _index => File('${root.path}/index.json');
  File get _backup => File('${root.path}/index.backup');

  Future<T> exclusive<T>(Future<T> Function() action) {
    final future = _queue.then((_) => action());
    _queue = future.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return future;
  }

  String directoryKey(String packId) =>
      sha256.convert(utf8.encode(packId)).toString();
  Directory versionDirectory(String packId, int version) =>
      Directory('${root.path}/packs/${directoryKey(packId)}/$version');

  Future<Map<String, dynamic>> readIndex() async {
    if (await _index.exists()) {
      try {
        return _normalizeIndex(jsonDecode(await _index.readAsString()));
      } catch (_) {
        if (await _backup.exists()) {
          try {
            final recovered =
                _normalizeIndex(jsonDecode(await _backup.readAsString()));
            final corrupt = File(
                '${root.path}/index.corrupt.${DateTime.now().microsecondsSinceEpoch}');
            await _index.rename(corrupt.path);
            await _backup.rename(_index.path);
            return recovered;
          } catch (_) {
            // 两份索引都损坏时保留文件并从空索引恢复。
          }
        }
        return _emptyIndex();
      }
    }
    if (await _backup.exists()) {
      try {
        final recovered =
            _normalizeIndex(jsonDecode(await _backup.readAsString()));
        await _backup.rename(_index.path);
        return recovered;
      } catch (_) {
        return _emptyIndex();
      }
    }
    return _emptyIndex();
  }

  Map<String, dynamic> _emptyIndex() => {
        'packs': <String, dynamic>{},
        'tombstones': <String, dynamic>{},
        'downloads': <String, dynamic>{},
        'versions': <String, dynamic>{},
      };

  Map<String, dynamic> _normalizeIndex(dynamic value) {
    if (value is! Map) throw const FormatException('表情索引格式无效');
    final index = Map<String, dynamic>.from(value);
    for (final key in const ['packs', 'tombstones', 'downloads', 'versions']) {
      final bucket = index[key];
      index[key] = bucket is Map
          ? Map<String, dynamic>.from(bucket)
          : <String, dynamic>{};
    }
    return index;
  }

  Future<void> writeIndex(Map<String, dynamic> value) async {
    await root.create(recursive: true);
    final temporary = File('${root.path}/index.tmp');
    await temporary.writeAsString(jsonEncode(value), flush: true);
    if (await _backup.exists()) await _backup.delete();
    if (await _index.exists()) await _index.rename(_backup.path);
    await temporary.rename(_index.path);
    if (await _backup.exists()) await _backup.delete();
  }

  Future<List<EmojiPackInstallation>> load() => exclusive(() async {
        final root = await readIndex();
        final packMap = root['packs'] as Map;
        final packs = <EmojiPackInstallation>[];
        var changed = false;
        for (final entry in packMap.entries.toList()) {
          try {
            final installation = EmojiPackInstallation.fromJson(
                Map<String, dynamic>.from(entry.value as Map));
            if (installation.packId != entry.key) {
              packMap.remove(entry.key);
              changed = true;
              continue;
            }
            packs.add(installation);
          } catch (_) {
            packMap.remove(entry.key);
            changed = true;
          }
        }
        if (changed) await writeIndex(root);
        packs.sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
        return packs;
      });

  /// 调用方持有 exclusive，安装器可把文件提交和索引更新放在同一事务序列。
  /// 返回真正落盘的那份记录：安装器要用它决定保留哪些版本目录。
  Future<EmojiPackInstallation> commit(
      EmojiPackInstallation installation) async {
    final root = await readIndex();
    final versions =
        root.putIfAbsent('versions', () => <String, dynamic>{}) as Map;
    final versionKey =
        '${directoryKey(installation.packId)}:${installation.version}';
    if (versions[versionKey] != null &&
        versions[versionKey] != installation.manifestSha256) {
      throw StateError('同版本表情包内容不可修改');
    }
    versions[versionKey] = installation.manifestSha256;
    final packs = root['packs'] as Map;
    final oldJson = packs[installation.packId];
    final old = oldJson == null
        ? null
        : EmojiPackInstallation.fromJson(
            Map<String, dynamic>.from(oldJson as Map));
    if (old != null &&
        old.version == installation.version &&
        old.manifestSha256 != installation.manifestSha256) {
      throw StateError('同版本表情包内容不可修改');
    }
    // 回滚指针只跟着「成功安装」向前移动：当前活动版本真的换了、且被换下的那份
    // 当初是安装成功的，才有资格成为上一版。标记损坏这类原地更新保持原指针。
    final currentChanged = old != null &&
        (old.version != installation.version ||
            old.manifestSha256 != installation.manifestSha256);
    final promoted = currentChanged &&
            installation.status == EmojiPackInstallStatus.installed &&
            old.status == EmojiPackInstallStatus.installed
        ? EmojiPackVersionRef(
            version: old.version, manifestSha256: old.manifestSha256)
        : null;
    final persisted =
        installation.copyWith(previous: promoted ?? old?.previous);
    packs[installation.packId] = persisted.toJson();
    (root['tombstones'] as Map).remove(installation.packId);
    await writeIndex(root);
    return persisted;
  }

  Future<int> storageBytes() => exclusive(() async {
        if (!await root.exists()) return 0;
        var total = 0;
        await for (final entity
            in root.list(recursive: true, followLinks: false)) {
          if (entity is File) total += await entity.length();
        }
        return total;
      });

  Future<void> setEnabled(String packId, bool enabled) => exclusive(() async {
        final root = await readIndex();
        final packs = root['packs'] as Map;
        final installation = EmojiPackInstallation.fromJson(
            Map<String, dynamic>.from(packs[packId] as Map));
        packs[packId] = installation.copyWith(enabled: enabled).toJson();
        await writeIndex(root);
      });

  Future<void> reorder(List<String> ids) => exclusive(() async {
        final root = await readIndex();
        final packs = root['packs'] as Map;
        if (ids.toSet().length != packs.length ||
            !ids.toSet().containsAll(packs.keys.cast<String>())) {
          throw ArgumentError('排序必须包含全部已安装表情包');
        }
        for (var i = 0; i < ids.length; i++) {
          final item = EmojiPackInstallation.fromJson(
              Map<String, dynamic>.from(packs[ids[i]] as Map));
          packs[ids[i]] = item.copyWith(sortOrder: i).toJson();
        }
        await writeIndex(root);
      });

  Future<void> remove(String packId) => exclusive(() async {
        final root = await readIndex();
        (root['packs'] as Map).remove(packId);
        (root['downloads'] as Map?)?.remove(packId);
        (root['tombstones'] as Map)[packId] =
            DateTime.now().toUtc().toIso8601String();
        await writeIndex(root);
        // 仅删除哈希目录中的本机副本，不请求服务端删除 File。
        final directory =
            Directory('${this.root.path}/packs/${directoryKey(packId)}');
        if (await directory.exists()) await directory.delete(recursive: true);
      });
}
