import 'emoji_pack.dart';
import 'emoji_pack_manifest.dart';

enum EmojiPackInstallStatus { installed, damaged, failed }

/// 本机安装关系独立于 Pack 目录和消息 File 引用。
class EmojiPackInstallation {
  const EmojiPackInstallation({
    required this.manifest,
    required this.manifestSha256,
    required this.name,
    required this.trustLevel,
    this.enabled = true,
    this.sortOrder = 0,
    this.status = EmojiPackInstallStatus.installed,
    this.error,
    this.externalPackId,
    this.importSourceSha256,
  });

  final EmojiPackManifest manifest;
  final String manifestSha256;
  final String name;
  final EmojiPackTrustLevel trustLevel;
  final bool enabled;
  final int sortOrder;
  final EmojiPackInstallStatus status;
  final String? error;

  /// 第三方 Manifest 自己声明的 pack_id。只是外部标识与展示线索，
  /// 绝不参与本地身份计算：两个包可以声明同一个外部 id。
  final String? externalPackId;

  /// 导入源文件的 SHA-256。重新导入同一个文件时用它找回已有本地包，
  /// 这是唯一不依赖外部声明的「同一个包」判据。
  final String? importSourceSha256;
  String get packId => manifest.packId;
  int get version => manifest.version;
  int get totalSize => manifest.totalSize;
  bool hasUpdate(int catalogVersion) => catalogVersion > version;

  EmojiPackInstallation copyWith(
          {bool? enabled,
          int? sortOrder,
          EmojiPackInstallStatus? status,
          String? error}) =>
      EmojiPackInstallation(
        manifest: manifest,
        manifestSha256: manifestSha256,
        name: name,
        trustLevel: trustLevel,
        enabled: enabled ?? this.enabled,
        sortOrder: sortOrder ?? this.sortOrder,
        status: status ?? this.status,
        error: error ?? this.error,
        externalPackId: externalPackId,
        importSourceSha256: importSourceSha256,
      );

  Map<String, dynamic> toJson() => {
        'manifest': manifest.toJson(),
        'manifest_sha256': manifestSha256,
        'name': name,
        'trust': trustLevel.name,
        'enabled': enabled,
        'sort_order': sortOrder,
        'status': status.name,
        if (error != null) 'error': error,
        if (externalPackId != null) 'external_pack_id': externalPackId,
        if (importSourceSha256 != null) 'import_source_sha256': importSourceSha256,
      };

  factory EmojiPackInstallation.fromJson(Map<String, dynamic> json) =>
      EmojiPackInstallation(
        manifest: EmojiPackManifest.fromJson(
            Map<String, dynamic>.from(json['manifest'] as Map)),
        manifestSha256: json['manifest_sha256'] as String,
        name: json['name'] as String,
        trustLevel: EmojiPackTrustLevel.values.byName(json['trust'] as String),
        enabled: json['enabled'] as bool,
        sortOrder: json['sort_order'] as int,
        status: EmojiPackInstallStatus.values.byName(json['status'] as String),
        error: json['error'] as String?,
        externalPackId: json['external_pack_id'] as String?,
        importSourceSha256: json['import_source_sha256'] as String?,
      );
}
