import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// 本地学校账号的设备侧身份。
///
/// [id] 是随机 UUID v4，与学号完全无关。该对象可以安全地用于 UI 状态和
/// 路由；密码、Cookie 等秘密只允许进入 [LocalSchoolCredentialVault]。
class LocalSchoolProfile {
  LocalSchoolProfile({
    required this.appUserId,
    required this.studentId,
    String? id,
    DateTime? createdAt,
    DateTime? lastActiveAt,
    this.displayName,
  })  : id = _validateId(id ?? randomId()),
        createdAt = (createdAt ?? DateTime.now().toUtc()).toUtc(),
        lastActiveAt = lastActiveAt?.toUtc() {
    if (appUserId.trim().isEmpty) {
      throw ArgumentError.value(appUserId, 'appUserId');
    }
    if (studentId.trim().isEmpty) {
      throw ArgumentError.value(studentId, 'studentId');
    }
    if (id == studentId.trim()) {
      throw ArgumentError('LocalSchoolProfile ID 不能使用学号');
    }
  }

  final String id;
  final String appUserId;
  final String studentId;
  final DateTime createdAt;
  final DateTime? lastActiveAt;
  final String? displayName;

  static final RegExp uuidV4Pattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    caseSensitive: false,
  );

  /// 使用系统安全随机源生成 UUID v4；不从学号、时间或可预测值派生。
  static String randomId({Random? random}) {
    final source = random ?? Random.secure();
    final bytes = Uint8List.fromList(
      List<int>.generate(16, (_) => source.nextInt(256)),
    );
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex =
        bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  factory LocalSchoolProfile.fromJson(Map<String, dynamic> json) {
    final id = json['id']?.toString().trim() ?? '';
    final appUserId = json['app_user_id']?.toString().trim() ?? '';
    final studentId = json['student_id']?.toString().trim() ?? '';
    final createdAt = DateTime.tryParse(json['created_at']?.toString() ?? '');
    final lastActiveAt = json['last_active_at'] == null
        ? null
        : DateTime.tryParse(json['last_active_at'].toString());
    if (id.isEmpty ||
        appUserId.isEmpty ||
        studentId.isEmpty ||
        createdAt == null) {
      throw const FormatException('本地学校 Profile 格式错误');
    }
    return LocalSchoolProfile(
      id: id,
      appUserId: appUserId,
      studentId: studentId,
      createdAt: createdAt,
      lastActiveAt: lastActiveAt,
      displayName: _optionalString(json['display_name']),
    );
  }

  /// Profile 元数据不包含密码、Cookie 或其他会话秘密。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'app_user_id': appUserId,
        'student_id': studentId,
        'created_at': createdAt.toUtc().toIso8601String(),
        if (lastActiveAt != null)
          'last_active_at': lastActiveAt!.toUtc().toIso8601String(),
        if (displayName != null) 'display_name': displayName,
      };

  String toMetadataJson() => jsonEncode(toJson());

  LocalSchoolProfile copyWith({
    String? studentId,
    DateTime? lastActiveAt,
    String? displayName,
  }) {
    return LocalSchoolProfile(
      id: id,
      appUserId: appUserId,
      studentId: studentId ?? this.studentId,
      createdAt: createdAt,
      lastActiveAt: lastActiveAt ?? this.lastActiveAt,
      displayName: displayName ?? this.displayName,
    );
  }

  @override
  String toString() => 'LocalSchoolProfile(id: $id, appUserId: <redacted>, '
      'studentId: <redacted>)';

  static String _validateId(String value) {
    final normalized = value.trim().toLowerCase();
    if (!uuidV4Pattern.hasMatch(normalized)) {
      throw ArgumentError.value(value, 'id', '必须是随机 UUID v4');
    }
    return normalized;
  }

  static String? _optionalString(Object? value) {
    final normalized = value?.toString().trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }
}

/// 学校登录所需的短生命周期秘密。
class LocalSchoolCredentials {
  const LocalSchoolCredentials({
    required this.studentId,
    this.password,
    this.cookie,
    this.sessionMetadata = const <String, dynamic>{},
  });

  final String studentId;
  final String? password;
  final String? cookie;
  final Map<String, dynamic> sessionMetadata;
}
