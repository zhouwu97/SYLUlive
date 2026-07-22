import '../config/api_constants.dart';

/// 客户端版本检查结果类型。
///
/// 服务端 [AppUpdateInfo.updateType] 是唯一可信源；客户端在任何情况下都不应
/// 自行根据 versionCode 推断强制状态。
enum AppUpdateType {
  /// 客户端已是最新或更新版本，不需要任何动作。
  none,

  /// 客户端版本低于最新但高于最低支持版本，可延迟升级。
  optional,

  /// 客户端版本低于最低支持版本，必须升级才能继续使用。
  required,
}

AppUpdateType _parseUpdateType(dynamic value) {
  if (value is String) {
    switch (value) {
      case 'none':
        return AppUpdateType.none;
      case 'optional':
        return AppUpdateType.optional;
      case 'required':
        return AppUpdateType.required;
    }
  }
  throw FormatException(
    'update_type 必须是 none/optional/required，收到: $value',
  );
}

/// 解析数字字段，允许 int 或可解析为 int 的字符串。
///
/// 服务端可能因 JSON 库差异返回 int 或字符串；但 null 与非数字字符串必须
/// 被严格拒绝，否则后续校验会沉默地放行非法策略。
int _parseInt(dynamic value, String fieldName) {
  if (value is int) return value;
  if (value is String) {
    final parsed = int.tryParse(value.trim());
    if (parsed != null) return parsed;
  }
  throw FormatException('$fieldName 必须是整数或数字字符串，收到: $value');
}

/// 校验 sha256 字符串是 64 位小写或大写十六进制。
///
/// 服务端 publish 流程会保证写入 64 位 hex；客户端校验失败就拒绝安装，
/// 不能让 32 字节或异常 hex 进入下一步文件比对。
void _validateSha256Hex(String value) {
  final hex = value.toLowerCase();
  if (hex.length != 64) {
    throw FormatException('sha256 长度必须为 64，收到 ${hex.length}');
  }
  for (final codeUnit in hex.codeUnits) {
    final isDigit = codeUnit >= 0x30 && codeUnit <= 0x39; // '0'-'9'
    final isLowerHex = codeUnit >= 0x61 && codeUnit <= 0x66; // 'a'-'f'
    if (!isDigit && !isLowerHex) {
      throw FormatException('sha256 含非法字符: $value');
    }
  }
}

/// 解析 ISO8601 时间字符串。空值返回 null；非空但无法解析则抛 FormatException。
DateTime? _parseNullableDate(String? value) {
  if (value == null || value.isEmpty) return null;
  final parsed = DateTime.tryParse(value);
  if (parsed == null) {
    throw FormatException('published_at 无法解析: $value');
  }
  return parsed.toUtc();
}

/// 服务端 GET /api/app/update 响应的客户端表示。
///
/// 服务端响应字段命名采用 snake_case；这里保持与服务端一致以避免未来线缆
/// 协议变更时的双名称映射。`downloadUrl` 已经通过 [ApiConstants.fullUrl]
/// 变成完整 URL，下游代码不需要再拼接 base。
class AppUpdateInfo {
  final bool updateAvailable;
  final AppUpdateType updateType;

  final String currentVersionName;
  final int currentVersionCode;

  final String latestVersionName;
  final int latestVersionCode;
  final int minimumSupportedVersionCode;

  final String title;
  final String changelog;

  final int fileSize;
  final String sha256;
  final String downloadUrl;

  final String? deliveryMode;
  final String? actionUrl;

  final DateTime? publishedAt;
  final int checkAfterSeconds;

  AppUpdateInfo({
    required this.updateAvailable,
    required this.updateType,
    required this.currentVersionName,
    required this.currentVersionCode,
    required this.latestVersionName,
    required this.latestVersionCode,
    required this.minimumSupportedVersionCode,
    required this.title,
    required this.changelog,
    required this.fileSize,
    required this.sha256,
    required this.downloadUrl,
    this.deliveryMode,
    this.actionUrl,
    required this.publishedAt,
    required this.checkAfterSeconds,
  });

  /// 转换为可持久化的服务端协议字段，供本地策略缓存恢复。
  /// 下载链接已在解析阶段转为绝对地址，恢复时会原样保留。
  Map<String, dynamic> toJson() => {
        'update_available': updateAvailable,
        'update_type': updateType.name,
        'current_version_name': currentVersionName,
        'current_version_code': currentVersionCode,
        'latest_version_name': latestVersionName,
        'latest_version_code': latestVersionCode,
        'minimum_supported_version_code': minimumSupportedVersionCode,
        'title': title,
        'changelog': changelog,
        'file_size': fileSize,
        'sha256': sha256,
        'download_url': downloadUrl,
        if (deliveryMode != null) 'delivery_mode': deliveryMode,
        if (actionUrl != null) 'action_url': actionUrl,
        if (publishedAt != null) 'published_at': publishedAt!.toIso8601String(),
        'check_after_seconds': checkAfterSeconds,
      };

  /// 从服务端 JSON 构造 AppUpdateInfo。
  ///
  /// 严格模式：
  ///   - update_type 必须是 none/optional/required 之一；
  ///   - version_code 必须可解析；
  ///   - 当 update_available 为 true 时 sha256 必须 64 位 hex；
  ///   - 相对 download_url 自动转绝对；空字符串保留为空。
  factory AppUpdateInfo.fromJson(Map<String, dynamic> json) {
    final updateType = _parseUpdateType(json['update_type']);
    final updateAvailable = json['update_available'] is bool
        ? json['update_available'] as bool
        : false;

    final latestVersionName = json['latest_version_name'];
    if (latestVersionName is! String || latestVersionName.isEmpty) {
      throw FormatException(
        'latest_version_name 必须是非空字符串，收到: $latestVersionName',
      );
    }
    final latestVersionCode =
        _parseInt(json['latest_version_code'], 'latest_version_code');
    if (latestVersionCode <= 0) {
      throw FormatException('latest_version_code 必须为正，收到: $latestVersionCode');
    }

    final currentVersionName = json['current_version_name'];
    if (currentVersionName is! String || currentVersionName.isEmpty) {
      throw FormatException(
        'current_version_name 必须是非空字符串，收到: $currentVersionName',
      );
    }
    final currentVersionCode =
        _parseInt(json['current_version_code'], 'current_version_code');

    // minimum_supported_version_code 在服务端无 published 行时是 0；
    // 不强制要求 > 0，但禁止负值。
    final minimumSupported = _parseInt(json['minimum_supported_version_code'],
        'minimum_supported_version_code');
    if (minimumSupported < 0) {
      throw FormatException(
          'minimum_supported_version_code 不能为负，收到: $minimumSupported');
    }

    final checkAfterSeconds = json['check_after_seconds'] is int
        ? json['check_after_seconds'] as int
        : 21600;

    // update_available 为 false 时，title/changelog/file/sha256/download_url
    // 允许为空字符串。为 true 时必须齐全且 sha256 必须为 64 位 hex。
    String title = '';
    String changelog = '';
    int fileSize = 0;
    String sha256 = '';
    String downloadUrl = '';

    if (updateAvailable) {
      title = (json['title'] ?? '') as String;
      changelog = (json['changelog'] ?? '') as String;
      fileSize = _parseInt(json['file_size'], 'file_size');
      if (fileSize <= 0) {
        throw FormatException('file_size 必须为正，收到: $fileSize');
      }
      final rawSha = json['sha256'];
      if (rawSha is! String || rawSha.isEmpty) {
        throw const FormatException('update_available=true 时 sha256 必须存在');
      }
      _validateSha256Hex(rawSha);
      sha256 = rawSha;

      final rawUrl = json['download_url'];
      if (rawUrl is! String || rawUrl.isEmpty) {
        if (json['delivery_mode'] != 'external_market') {
          throw const FormatException(
              'update_available=true 且非 external_market 时 download_url 必须存在');
        }
      } else {
        // 相对路径（如 /api/app/releases/12/download）经 ApiConstants.fullUrl
        // 拼成完整 https URL；绝对 URL 直接透传。
        final absoluteUrl = ApiConstants.fullUrl(rawUrl);
        if (absoluteUrl.isEmpty) {
          throw FormatException('download_url 转绝对后为空，原始值: $rawUrl');
        }
        downloadUrl = absoluteUrl;
      }
    }

    final deliveryMode = json['delivery_mode'] as String?;
    final actionUrl = json['action_url'] as String?;

    final publishedAt = _parseNullableDate(
      json['published_at'] is String ? json['published_at'] as String : null,
    );

    return AppUpdateInfo(
      updateAvailable: updateAvailable,
      updateType: updateType,
      currentVersionName: currentVersionName,
      currentVersionCode: currentVersionCode,
      latestVersionName: latestVersionName,
      latestVersionCode: latestVersionCode,
      minimumSupportedVersionCode: minimumSupported,
      title: title,
      changelog: changelog,
      fileSize: fileSize,
      sha256: sha256,
      downloadUrl: downloadUrl,
      deliveryMode: deliveryMode,
      actionUrl: actionUrl,
      publishedAt: publishedAt,
      checkAfterSeconds: checkAfterSeconds,
    );
  }

  @override
  String toString() => 'AppUpdateInfo(updateAvailable=$updateAvailable, '
      'updateType=$updateType, current=$currentVersionCode, '
      'latest=$latestVersionCode, min=$minimumSupportedVersionCode)';
}
