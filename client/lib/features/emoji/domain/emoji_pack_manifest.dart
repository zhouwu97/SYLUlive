/// `.sylupack` 中 manifest.json 的规范化模型。
class EmojiPackManifest {
  const EmojiPackManifest({
    required this.schemaVersion,
    required this.packId,
    required this.version,
    required this.totalSize,
    required this.assets,
  });

  final int schemaVersion;
  final String packId;
  final int version;
  final int totalSize;
  final List<EmojiManifestAsset> assets;

  factory EmojiPackManifest.fromJson(Map<String, dynamic> json) {
    final assetsJson = json['assets'];
    if (assetsJson is! List) {
      throw const FormatException('Pack manifest 缺少 assets');
    }
    final manifest = EmojiPackManifest(
      schemaVersion: _requiredInt(
          json['schema_version'] ?? json['schemaVersion'], 'schemaVersion'),
      packId: _requiredString(json['pack_id'] ?? json['packId'], 'packId'),
      version: _requiredInt(json['version'], 'version'),
      totalSize:
          _requiredInt(json['total_size'] ?? json['totalSize'], 'totalSize'),
      assets: assetsJson.map((value) {
        if (value is! Map) {
          throw const FormatException('Pack manifest asset 格式无效');
        }
        return EmojiManifestAsset.fromJson(Map<String, dynamic>.from(value));
      }).toList(growable: false),
    );
    manifest.validate();
    return manifest;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'schema_version': schemaVersion,
        'pack_id': packId,
        'version': version,
        'total_size': totalSize,
        'assets': assets.map((asset) => asset.toJson()).toList(growable: false),
      };

  /// 仅校验 manifest 自身的一致性；压缩包路径和文件内容由 Importer 校验。
  void validate() {
    if (schemaVersion != 1) throw const FormatException('schemaVersion 不受支持');
    if (packId.trim().isEmpty || packId.contains(':')) {
      throw const FormatException('packId 无效');
    }
    if (version < 1) throw const FormatException('Pack version 无效');
    if (totalSize < 0) throw const FormatException('Pack totalSize 无效');
    final ids = <String>{};
    final paths = <String>{};
    var calculatedSize = 0;
    for (final asset in assets) {
      asset.validate();
      if (asset.path.toLowerCase() == 'manifest.json') {
        throw const FormatException('资源路径不能覆盖 Manifest');
      }
      if (!ids.add(asset.id)) {
        throw FormatException('Pack asset id 重复: ${asset.id}');
      }
      if (!paths.add(asset.path.toLowerCase())) {
        throw const FormatException('Pack asset 路径重复');
      }
      calculatedSize += asset.fileSize;
    }
    if (calculatedSize != totalSize) {
      throw FormatException(
        'Pack totalSize 不一致: manifest=$totalSize calculated=$calculatedSize',
      );
    }
  }

  static int _requiredInt(Object? value, String name) {
    final parsed = value is num ? value.toInt() : int.tryParse('$value');
    if (parsed == null) throw FormatException('$name 缺失或无效');
    return parsed;
  }

  static String _requiredString(Object? value, String name) {
    final parsed = value?.toString().trim() ?? '';
    if (parsed.isEmpty) throw FormatException('$name 缺失或无效');
    return parsed;
  }
}

class EmojiManifestAsset {
  static const Set<String> supportedMimeTypes = <String>{
    'image/png',
    'image/jpeg',
    'image/gif',
  };

  const EmojiManifestAsset({
    required this.id,
    required this.path,
    required this.name,
    required this.sha256,
    required this.mimeType,
    required this.fileSize,
    this.keywords = const <String>[],
    this.width,
    this.height,
    this.animated = false,
  });

  final String id;
  final String path;
  final String name;
  final List<String> keywords;
  final String sha256;
  final String mimeType;
  final int fileSize;
  final int? width;
  final int? height;
  final bool animated;

  factory EmojiManifestAsset.fromJson(Map<String, dynamic> json) {
    final keywords = json['keywords'];
    return EmojiManifestAsset(
      id: _requiredString(json['id'], 'asset.id'),
      path: _requiredString(json['path'], 'asset.path'),
      name: _requiredString(json['name'], 'asset.name'),
      sha256: _requiredString(json['sha256'], 'asset.sha256'),
      mimeType: _requiredString(
          json['mime_type'] ?? json['mimeType'], 'asset.mimeType'),
      fileSize:
          _requiredInt(json['file_size'] ?? json['fileSize'], 'asset.fileSize'),
      keywords: keywords is List
          ? keywords.map((value) => value.toString()).toList(growable: false)
          : const <String>[],
      width: _optionalInt(json['width']),
      height: _optionalInt(json['height']),
      animated: json['animated'] == true,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'path': path,
        'name': name,
        'keywords': keywords,
        'sha256': sha256,
        'mime_type': mimeType,
        'file_size': fileSize,
        if (width != null) 'width': width,
        if (height != null) 'height': height,
        if (animated) 'animated': true,
      };

  void validate() {
    if (id.trim().isEmpty || id.contains(':')) {
      throw const FormatException('asset.id 无效');
    }
    if (path.trim().isEmpty ||
        path.startsWith('/') ||
        path.contains('\\') ||
        RegExp(r'[:\x00-\x1f]').hasMatch(path)) {
      throw const FormatException('asset.path 必须是相对 POSIX 路径');
    }
    final segments = path.split('/');
    if (segments.any((segment) =>
        segment.isEmpty ||
        segment == '.' ||
        segment == '..' ||
        segment.endsWith('.') ||
        segment.endsWith(' ') ||
        RegExp(r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\.|$)',
                caseSensitive: false)
            .hasMatch(segment))) {
      throw const FormatException('asset.path 包含非法路径段');
    }
    if (!RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(sha256)) {
      throw const FormatException('asset.sha256 必须是 SHA-256');
    }
    if (!supportedMimeTypes.contains(mimeType.toLowerCase())) {
      throw FormatException('暂不支持的表情资源 MIME: $mimeType');
    }
    if (fileSize < 0 ||
        width != null && width! <= 0 ||
        height != null && height! <= 0) {
      throw const FormatException('asset 媒体尺寸或大小无效');
    }
  }

  static String _requiredString(Object? value, String name) {
    final parsed = value?.toString().trim() ?? '';
    if (parsed.isEmpty) throw FormatException('$name 缺失或无效');
    return parsed;
  }

  static int _requiredInt(Object? value, String name) {
    final parsed = value is num ? value.toInt() : int.tryParse('$value');
    if (parsed == null) throw FormatException('$name 缺失或无效');
    return parsed;
  }

  static int? _optionalInt(Object? value) {
    if (value == null) return null;
    return value is num ? value.toInt() : int.tryParse('$value');
  }
}
