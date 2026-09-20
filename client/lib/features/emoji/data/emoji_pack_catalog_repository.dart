import 'package:dio/dio.dart';
import '../domain/emoji_pack_manifest.dart';
import '../application/emoji_pack_installer.dart';

class EmojiCatalogEntry {
  const EmojiCatalogEntry(
      {required this.id,
      required this.name,
      required this.version,
      required this.assetCount,
      required this.totalSize,
      required this.manifestSha256});
  final String id;
  final String name;
  final int version;
  final int assetCount;
  final int totalSize;
  final String manifestSha256;
  factory EmojiCatalogEntry.fromJson(Map<String, dynamic> json) {
    final entry = EmojiCatalogEntry(
        id: json['id'] as String,
        name: json['name'] as String,
        version: json['version'] as int,
        assetCount: json['asset_count'] as int,
        totalSize: json['total_size'] as int,
        manifestSha256: json['manifest_sha256'] as String);
    if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(entry.id) ||
        entry.version < 1 ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(entry.manifestSha256)) {
      throw const FormatException('官方目录无效');
    }
    return entry;
  }
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'version': version,
        'asset_count': assetCount,
        'total_size': totalSize,
        'manifest_sha256': manifestSha256
      };
}

class EmojiPackCatalogRepository {
  EmojiPackCatalogRepository(this.dio) {
    if (Uri.parse(dio.options.baseUrl).scheme != 'https') {
      throw ArgumentError('官方目录必须使用 HTTPS');
    }
  }
  final Dio dio;
  Future<List<EmojiCatalogEntry>> list() async {
    final response =
        await dio.get('/emoji/packs', options: Options(followRedirects: false));
    return (response.data as List)
        .map((e) =>
            EmojiCatalogEntry.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  Future<EmojiPackManifest> manifest(
      EmojiCatalogEntry entry, CancelToken token) async {
    final response = await dio.get('/emoji/packs/${entry.id}/manifest',
        queryParameters: {'version': entry.version},
        cancelToken: token,
        options: Options(followRedirects: false));
    final manifest = EmojiPackManifest.fromJson(
        Map<String, dynamic>.from(response.data as Map));
    if (manifest.packId != entry.id ||
        manifest.version != entry.version ||
        manifest.assets.length != entry.assetCount ||
        manifest.totalSize != entry.totalSize ||
        EmojiPackInstaller.manifestHash(manifest) != entry.manifestSha256) {
      throw const FormatException('官方 Manifest 与目录不一致');
    }
    return manifest;
  }
}
