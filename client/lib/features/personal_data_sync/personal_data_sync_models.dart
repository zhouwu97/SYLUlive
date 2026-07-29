import 'personal_data_source.dart';

/// 可由统一入口请求更新的个人数据集。
enum PersonalSyncDataset {
  schedule,
  grades,
  academicSituation,
  creditRequirements,
  erke,
}

/// 同步发起位置用于审计和界面统计，不参与数据访问授权。
enum PersonalSyncTrigger {
  assistant,
  vault,
  academicPage,
  schedulePage,
  erkePage
}

/// 跨端共享的数据可用性状态；额外的本地错误应映射为 failed，而不是新增 wire 值。
enum PersonalDataStatus {
  available,
  stale,
  missing,
  needsRefresh,
  corrupted,
  partial,
  permissionRequired,
  deviceOffline,
  fetching,
  failed,
}

extension PersonalDataStatusWireValue on PersonalDataStatus {
  String get wireValue => switch (this) {
        PersonalDataStatus.available => 'available',
        PersonalDataStatus.stale => 'stale',
        PersonalDataStatus.missing => 'missing',
        PersonalDataStatus.needsRefresh => 'needs_refresh',
        PersonalDataStatus.corrupted => 'corrupted',
        PersonalDataStatus.partial => 'partial',
        PersonalDataStatus.permissionRequired => 'permission_required',
        PersonalDataStatus.deviceOffline => 'device_offline',
        PersonalDataStatus.fetching => 'fetching',
        PersonalDataStatus.failed => 'failed',
      };

  static PersonalDataStatus fromWireValue(String value) => switch (value) {
        'available' => PersonalDataStatus.available,
        'stale' => PersonalDataStatus.stale,
        'missing' => PersonalDataStatus.missing,
        'needs_refresh' => PersonalDataStatus.needsRefresh,
        'corrupted' => PersonalDataStatus.corrupted,
        'partial' => PersonalDataStatus.partial,
        'permission_required' => PersonalDataStatus.permissionRequired,
        'device_offline' => PersonalDataStatus.deviceOffline,
        'fetching' => PersonalDataStatus.fetching,
        'failed' => PersonalDataStatus.failed,
        _ => throw FormatException('未知个人数据状态：$value'),
      };
}

/// 单条来源证据，用于回答页面的来源、更新时间和过期状态展示。
class PersonalDataEvidence {
  const PersonalDataEvidence({
    required this.source,
    required this.dataset,
    this.scopeKey,
    this.fetchedAt,
    this.expiresAt,
    this.isStale = false,
  });

  final PersonalDataSource source;
  final String dataset;
  final String? scopeKey;
  final DateTime? fetchedAt;
  final DateTime? expiresAt;
  final bool isStale;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'source': source.wireValue,
        'dataset': dataset,
        if (scopeKey != null && scopeKey!.isNotEmpty) 'scope_key': scopeKey,
        if (fetchedAt != null)
          'fetched_at': fetchedAt!.toUtc().toIso8601String(),
        if (expiresAt != null)
          'expires_at': expiresAt!.toUtc().toIso8601String(),
        'is_stale': isStale,
      };
}

/// 个人数据工具和同步任务的通用结果信封。
/// data 只能包含完成当前任务所需的裁剪业务数据。
class PersonalDataResult<T> {
  PersonalDataResult({
    required this.data,
    required this.status,
    required this.source,
    this.fetchedAt,
    this.expiresAt,
    this.isStale = false,
    this.isPartial = false,
    List<String> warnings = const <String>[],
    List<PersonalDataEvidence> evidence = const <PersonalDataEvidence>[],
  })  : warnings = List<String>.unmodifiable(warnings),
        evidence = List<PersonalDataEvidence>.unmodifiable(evidence);

  final T? data;
  final PersonalDataStatus status;
  final PersonalDataSource source;
  final DateTime? fetchedAt;
  final DateTime? expiresAt;
  final bool isStale;
  final bool isPartial;
  final List<String> warnings;
  final List<PersonalDataEvidence> evidence;

  bool get hasData => data != null;

  Map<String, dynamic> toJson(Object? Function(T value) encodeData) =>
      <String, dynamic>{
        'data': data == null ? <String, dynamic>{} : encodeData(data as T),
        'status': status.wireValue,
        'source': source.wireValue,
        if (fetchedAt != null)
          'fetched_at': fetchedAt!.toUtc().toIso8601String(),
        if (expiresAt != null)
          'expires_at': expiresAt!.toUtc().toIso8601String(),
        'is_stale': isStale,
        'is_partial': isPartial,
        'warnings': warnings,
        'evidence':
            evidence.map((item) => item.toJson()).toList(growable: false),
      };
}
