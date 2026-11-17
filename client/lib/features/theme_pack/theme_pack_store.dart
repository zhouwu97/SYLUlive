import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'theme_manifest.dart';
import 'theme_pack_codec.dart';

class InstalledTheme {
  const InstalledTheme(this.manifest, this.directory, this.installedAt);
  final ThemeManifest manifest;
  final String directory;
  final String installedAt;
}

/// 修改由 ThemeProvider 的现有外观写入队列串行调用。
class ThemePackStore {
  const ThemePackStore({Directory? directory}) : _directory = directory;
  final Directory? _directory;

  Future<Directory> get directory async =>
      _directory ??
      Directory(
          path.join((await getApplicationDocumentsDirectory()).path, 'themes'));

  Future<List<InstalledTheme>> list() async {
    final root = await directory;
    final file = File(path.join(root.path, 'index.json'));
    if (!await file.exists()) return [];
    final entries = jsonDecode(await file.readAsString()) as List;
    final result = <InstalledTheme>[];
    for (final entry in entries) {
      final folder = path.join(
          root.path, 'installed', entry['id'] as String, '${entry['version']}');
      final manifest = ThemeManifest.fromStored(jsonDecode(
              await File(path.join(folder, 'manifest.json')).readAsString())
          as Map<String, dynamic>);
      result.add(
          InstalledTheme(manifest, folder, entry['installedAt'] as String));
    }
    result.sort((a, b) => b.installedAt.compareTo(a.installedAt));
    return result;
  }

  Future<InstalledTheme> install(PreparedThemePack pack) async {
    final root = await directory;
    final manifest = pack.manifest;
    final destination = Directory(
        path.join(root.path, 'installed', manifest.id, '${manifest.version}'));
    if (await destination.exists()) {
      throw const ThemePackError(
          'theme_field_invalid', 'version', '这个版本已安装，请从本机主题中应用');
    }
    final index = await list();
    final stagingRoot = await Directory(path.join(root.path, '.staging'))
        .create(recursive: true);
    final staging = await stagingRoot.createTemp('import-');
    var published = false;
    var indexed = false;
    try {
      for (final entry in pack.contents.entries) {
        final file = File(path.join(staging.path, entry.key));
        await file.parent.create(recursive: true);
        await file.writeAsBytes(entry.value, flush: true);
      }
      await File(path.join(staging.path, 'manifest.json'))
          .writeAsString(jsonEncode(manifest.data), flush: true);
      await destination.parent.create(recursive: true);
      await staging.rename(destination.path);
      published = true;
      final installed = InstalledTheme(
          manifest, destination.path, DateTime.now().toUtc().toIso8601String());
      final old =
          index.where((item) => item.manifest.id == manifest.id).firstOrNull;
      if (old == null || old.manifest.version < manifest.version) {
        await _writeIndex(root, [
          ...index.where((item) => item.manifest.id != manifest.id),
          installed
        ]);
      }
      indexed = true;
      return installed;
    } finally {
      if (!indexed) {
        await _removeManaged(root, published ? destination : staging);
      }
    }
  }

  Future<void> remove(String id) async {
    final root = await directory;
    await _writeIndex(
        root, (await list()).where((item) => item.manifest.id != id).toList());
  }

  Future<void> _writeIndex(Directory root, List<InstalledTheme> themes) async {
    await root.create(recursive: true);
    final temp = File(path.join(root.path, 'index.json.tmp'));
    await temp.writeAsString(
        jsonEncode([
          for (final theme in themes)
            {
              'id': theme.manifest.id,
              'version': theme.manifest.version,
              'name': theme.manifest.name,
              'author': theme.manifest.author,
              'source': 'local',
              'familyId': null,
              'installedAt': theme.installedAt,
            }
        ]),
        flush: true);
    await temp.rename(path.join(root.path, 'index.json'));
  }

  Future<Uint8List> export(InstalledTheme theme) async =>
      ThemePackCodec.encode(theme.manifest, {
        for (final asset
            in theme.manifest.assets.map((asset) => asset.path).toSet())
          asset: await File(path.join(theme.directory, asset)).readAsBytes(),
      });

  Future<void> cleanup(
      {required Iterable<String> retainedPaths,
      required Iterable<(String, int)> retainedVersions}) async {
    final root = await directory;
    final index = await list();
    final paths = retainedPaths.map(path.normalize).toSet();
    final versions = {
      ...retainedVersions,
      for (final item in index) (item.manifest.id, item.manifest.version)
    };
    final installed = Directory(path.join(root.path, 'installed'));
    if (await installed.exists()) {
      await for (final id in installed.list(followLinks: false)) {
        if (id is! Directory) continue;
        await for (final version in id.list(followLinks: false)) {
          if (version is! Directory) continue;
          final referenced = versions.any((ref) =>
                  path.normalize(version.path) ==
                  path.normalize(
                      path.join(installed.path, ref.$1, '${ref.$2}'))) ||
              paths.any((ref) => path.isWithin(version.path, ref));
          if (!referenced) await _removeManaged(root, version);
        }
      }
    }
    final users = Directory(path.join(root.path, 'user'));
    if (await users.exists()) {
      await for (final file in users.list(followLinks: false)) {
        if (file is! File || file.path.endsWith('.verified')) continue;
        if (!paths.contains(path.normalize(file.path))) {
          await _removeManaged(root, file);
          final marker = File('${file.path}.verified');
          if (await marker.exists()) await _removeManaged(root, marker);
        }
      }
    }
  }

  Future<String> adoptWallpaper(String source) async {
    final root = await directory;
    if (path.isWithin(path.join(root.path, 'user'), source)) return source;
    final old = File(source);
    if (!await old.exists()) return source;
    final user =
        await Directory(path.join(root.path, 'user')).create(recursive: true);
    final temp = await user.createTemp('wallpaper-');
    final target = path.join(
        user.path, '${path.basename(temp.path)}${path.extension(source)}');
    try {
      await old.copy(target);
      final marker = File('$source.verified');
      if (await marker.exists()) await marker.copy('$target.verified');
      return target;
    } finally {
      await _removeManaged(root, temp);
    }
  }

  Future<InstalledTheme?> findInstalledVersion(String id, int version) async {
    final root = await directory;
    final folder = Directory(path.join(root.path, 'installed', id, '$version'));
    final manifestFile = File(path.join(folder.path, 'manifest.json'));
    if (!await manifestFile.exists()) return null;
    final manifest = ThemeManifest.fromStored(
      jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>,
    );
    return InstalledTheme(
      manifest,
      folder.path,
      DateTime.now().toUtc().toIso8601String(),
    );
  }

  Future<String> stageTrial(PreparedThemePack pack) async {
    final root = await directory;
    final stagingRoot = await Directory(path.join(root.path, '.staging'))
        .create(recursive: true);
    final staging = await stagingRoot.createTemp('trial-');
    try {
      for (final entry in pack.contents.entries) {
        final file = File(path.join(staging.path, entry.key));
        await file.parent.create(recursive: true);
        await file.writeAsBytes(entry.value, flush: true);
      }
      return staging.path;
    } catch (_) {
      await _removeManaged(root, staging);
      rethrow;
    }
  }

  Future<void> removeStagingDirectory(String? stagingPath) async {
    if (stagingPath == null || stagingPath.isEmpty) return;
    final root = await directory;
    final stagingRoot = path.normalize(path.join(root.path, '.staging'));
    final target = path.normalize(stagingPath);
    if (!path.isWithin(stagingRoot, target)) return;
    await _removeManaged(root, Directory(target));
  }

  Future<void> clearStaging({String? keepIncomingPath}) async {
    final root = await directory;
    final staging = Directory(path.join(root.path, '.staging'));
    if (await staging.exists()) {
      await for (final item in staging.list(followLinks: false)) {
        await _removeManaged(root, item);
      }
    }
    try {
      final tempDir = await getTemporaryDirectory();
      final incoming = Directory(path.join(tempDir.path, 'incoming-theme'));
      if (await incoming.exists()) {
        final normalizedKeep = keepIncomingPath == null
            ? null
            : path.normalize(path.absolute(keepIncomingPath));
        await for (final item in incoming.list(followLinks: false)) {
          final current = path.normalize(path.absolute(item.path));
          if (normalizedKeep != null && current == normalizedKeep) continue;
          if (await item.exists()) {
            await item.delete(recursive: item is Directory);
          }
        }
      }
    } catch (_) {}
  }

  Future<void> removeLegacyWallpaper(String source) async {
    final root = await directory;
    final legacyRoot = path.join(root.parent.path, 'wallpapers', 'custom');
    if (!path.isWithin(legacyRoot, source)) return;
    for (final name in [source, '$source.verified']) {
      final file = File(name);
      if (await file.exists()) await file.delete();
    }
  }

  Future<void> _removeManaged(Directory root, FileSystemEntity entity) async {
    final absoluteRoot = path.normalize(path.absolute(root.path));
    final target = path.normalize(path.absolute(entity.path));
    if (!path.isWithin(absoluteRoot, target)) throw StateError('主题清理路径越界');
    if (await entity.exists()) {
      await entity.delete(recursive: entity is Directory);
    }
  }
}
