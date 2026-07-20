enum PersonalDataType { academic, schedule, physical, erke }

extension PersonalDataTypeStorage on PersonalDataType {
  String get storageValue => switch (this) {
        PersonalDataType.academic => 'academic',
        PersonalDataType.schedule => 'schedule',
        PersonalDataType.physical => 'physical',
        PersonalDataType.erke => 'erke',
      };

  static PersonalDataType fromStorage(String value) => switch (value) {
        'academic' => PersonalDataType.academic,
        'schedule' => PersonalDataType.schedule,
        'physical' => PersonalDataType.physical,
        'erke' => PersonalDataType.erke,
        _ => throw const FormatException('未知个人数据类型'),
      };
}

/// 已通过密文认证和账号归属校验的本地个人数据快照。
class PersonalSnapshot {
  PersonalSnapshot({
    required this.appUserFingerprint,
    required this.sourceAccountFingerprint,
    required this.type,
    required this.schemaVersion,
    required this.encryptionVersion,
    required this.fetchedAt,
    required this.contentHash,
    required Map<String, dynamic> payload,
    this.expiresAt,
  }) : payload = Map<String, dynamic>.unmodifiable(payload);

  final String appUserFingerprint;
  final String sourceAccountFingerprint;
  final PersonalDataType type;
  final int schemaVersion;
  final int encryptionVersion;
  final DateTime fetchedAt;
  final DateTime? expiresAt;
  final String contentHash;
  final Map<String, dynamic> payload;

  bool get isStale =>
      expiresAt != null && !DateTime.now().toUtc().isBefore(expiresAt!);
}

class PersonalSnapshotStoreException implements Exception {
  const PersonalSnapshotStoreException(this.message);

  final String message;

  @override
  String toString() => message;
}
