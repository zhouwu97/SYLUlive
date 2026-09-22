import 'emoji_pack.dart';
import 'emoji_pack_manifest.dart';

enum EmojiPackInstallStatus { installed, damaged, failed }

/// 一次成功安装的版本身份。
///
/// `version` 只是包作者自报或内容哈希派生的序号，**不代表发布先后**；回滚因此
/// 只能跟着这条历史指针走，不能按数值大小挑「更早」的版本。
class EmojiPackVersionRef {
  const EmojiPackVersionRef(
      {required this.version, required this.manifestSha256});

  final int version;
  final String manifestSha256;

  Map<String, dynamic> toJson() =>
      {'version': version, 'manifest_sha256': manifestSha256};

  factory EmojiPackVersionRef.fromJson(Map<String, dynamic> json) =>
      EmojiPackVersionRef(
        version: json['version'] as int,
        manifestSha256: json['manifest_sha256'] as String,
      );
}

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
    this.previous,
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

  /// 上一次**成功安装**且仍作为回滚候选的版本。null 表示本机没有可回滚的历史
  /// （首次安装，或索引来自还没有该字段的旧版本——此时不猜测顺序）。
  final EmojiPackVersionRef? previous;
  String get packId => manifest.packId;
  int get version => manifest.version;
  int get totalSize => manifest.totalSize;
  bool hasUpdate(int catalogVersion) => catalogVersion > version;

  EmojiPackInstallation copyWith(
          {bool? enabled,
          int? sortOrder,
          EmojiPackInstallStatus? status,
          String? error,
          EmojiPackVersionRef? previous}) =>
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
        previous: previous ?? this.previous,
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
        if (previous != null) 'previous': previous!.toJson(),
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
        previous: json['previous'] == null
            ? null
            : EmojiPackVersionRef.fromJson(
                Map<String, dynamic>.from(json['previous'] as Map)),
      );
}
