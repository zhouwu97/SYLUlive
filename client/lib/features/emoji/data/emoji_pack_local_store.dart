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
    if (!await _index.exists() && await _backup.exists()) {
      await _backup.rename(_index.path);
    }
    if (!await _index.exists()) {
      return {'packs': <String, dynamic>{}, 'tombstones': <String, dynamic>{}};
    }
    return Map<String, dynamic>.from(
        jsonDecode(await _index.readAsString()) as Map);
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
        final packs = (root['packs'] as Map)
            .values
            .map((e) => EmojiPackInstallation.fromJson(
                Map<String, dynamic>.from(e as Map)))
            .toList();
        packs.sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
        return packs;
      });

  /// 调用方持有 exclusive，安装器可把文件提交和索引更新放在同一事务序列。
  Future<void> commit(EmojiPackInstallation installation) async {
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
    if (oldJson != null) {
      final old = EmojiPackInstallation.fromJson(
          Map<String, dynamic>.from(oldJson as Map));
      if (old.version == installation.version &&
          old.manifestSha256 != installation.manifestSha256) {
        throw StateError('同版本表情包内容不可修改');
      }
    }
    packs[installation.packId] = installation.toJson();
    (root['tombstones'] as Map).remove(installation.packId);
    await writeIndex(root);
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
