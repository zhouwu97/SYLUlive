import 'package:dio/dio.dart';

import '../models/security_event.dart';
import 'publish_session_scope.dart';

class SecurityBlockGroup {
  const SecurityBlockGroup({
    required this.id,
    required this.sourceFingerprint,
    required this.routePrefixes,
    required this.reason,
    required this.expiresAt,
    required this.createdBy,
  });

  final int id;
  final String sourceFingerprint;
  final List<String> routePrefixes;
  final String reason;
  final DateTime expiresAt;
  final int createdBy;
}

class SecurityLogEntry {
  const SecurityLogEntry({
    required this.id,
    required this.adminId,
    required this.adminName,
    required this.action,
    required this.target,
    required this.detail,
    required this.createdAt,
  });

  factory SecurityLogEntry.fromJson(Map<String, dynamic> json) =>
      SecurityLogEntry(
        id: (json['id'] as num?)?.toInt() ?? 0,
        adminId: (json['admin_id'] as num?)?.toInt() ?? 0,
        adminName: json['admin_name']?.toString() ?? '',
        action: json['action']?.toString() ?? '',
        target: json['target']?.toString() ?? '',
        detail: json['detail']?.toString() ?? '',
        createdAt: DateTime.tryParse(json['created_at']?.toString() ?? '')
                ?.toLocal() ??
            DateTime.fromMillisecondsSinceEpoch(0),
      );

  final int id;
  final int adminId;
  final String adminName;
  final String action;
  final String target;
  final String detail;
  final DateTime createdAt;

  String get actionLabel => switch (action) {
        'security_event_resolved' => '结案',
        'security_event_false_positive' => '标为误报',
        'security_block_created' => '封禁来源',
        'security_block_revoked' => '解除封禁',
        _ => action.isEmpty ? '安全操作' : action,
      };

  String get targetLabel {
    if (action.startsWith('security_event_')) return '事件 #$target';
    if (action == 'security_block_revoked') return '封禁 #$target';
    return target.isEmpty ? '' : '来源 $target';
  }
}

class SecurityEventPage {
  const SecurityEventPage(
      {required this.items,
      required this.page,
      required this.limit,
      this.total});
  final List<SecurityEvent> items;
  final int page;
  final int limit;
  final int? total;
  bool get hasMore =>
      items.isNotEmpty &&
      (total == null ? items.length >= limit : page * limit < total!);
}

class AdminSecurityService {
  final Dio dio;

  const AdminSecurityService(this.dio);

  Future<List<SecurityBlockGroup>> loadBlocks(
      {PublishSessionScope? session}) async {
    final rows = <Map>[];
    for (var page = 1;; page++) {
      // 管理员与超级管理员共用；来源键原值只在超级管理员响应中出现。
      final response = await dio.get('/admin/security/blocks',
          queryParameters: {'page': page},
          options: Options(extra: session?.requestExtra));
      final batch = (response.data as List).whereType<Map>().toList();
      rows.addAll(batch);
      if (batch.length < 200) break;
    }
    final groups = <String, List<Map>>{};
    for (final row in rows) {
      final groupId = row['group_id']?.toString() ?? '';
      final key = groupId.isNotEmpty
          ? groupId
          : '${row['source_key']}|${row['created_at']}|${row['expires_at']}|${row['reason']}|${row['created_by']}';
      groups.putIfAbsent(key, () => []).add(row);
    }
    return groups.values.map((items) {
      final first = items.first;
      return SecurityBlockGroup(
        id: (first['id'] as num).toInt(),
        sourceFingerprint: first['source_fingerprint']?.toString() ?? '',
        routePrefixes: items
            .map((item) => item['route_prefix']?.toString() ?? '')
            .toList(growable: false),
        reason: first['reason']?.toString() ?? '',
        expiresAt: DateTime.parse(first['expires_at'].toString()),
        createdBy: (first['created_by'] as num?)?.toInt() ?? 0,
      );
    }).toList(growable: false);
  }

  Future<void> revokeBlock(int id, {PublishSessionScope? session}) async {
    await dio.delete('/admin/security/blocks/$id',
        options: Options(extra: session?.requestExtra));
  }

  Future<SecurityOverview> loadOverview(
      {String range = '24h', PublishSessionScope? session}) async {
    final response = await dio.get('/admin/security/overview',
        queryParameters: {'range': range},
        options: Options(extra: session?.requestExtra));
    return SecurityOverview.fromJson(
        Map<String, dynamic>.from(response.data as Map));
  }

  /// 加载安全事件列表。
  ///
  /// [actionable] 传 'true' 只看待处置事件（默认页面口径），'false' 只看审计流水，
  /// 'all' 返回全部。审计流水包含正常验证码、正常改密、单次密码输错，
  /// 不应该混在待办里把列表刷满。
  Future<List<SecurityEvent>> loadEvents({
    String severity = 'all',
    String status = 'all',
    String actionable = 'all',
    int page = 1,
    PublishSessionScope? session,
  }) async =>
      (await loadEventPage(
              severity: severity,
              status: status,
              actionable: actionable,
              page: page,
              session: session))
          .items;

  Future<SecurityEventPage> loadEventPage({
    String severity = 'all',
    String status = 'all',
    String actionable = 'all',
    int page = 1,
    PublishSessionScope? session,
  }) async {
    final response = await dio.get('/admin/security/events',
        queryParameters: {
          'severity': severity,
          'status': status,
          'actionable': actionable,
          'page': page,
          'limit': 50,
        },
        options: Options(extra: session?.requestExtra));
    final data = Map<String, dynamic>.from(response.data as Map);
    final items = data['items'] as List? ?? const [];
    final events = items
        .whereType<Map>()
        .map((item) => SecurityEvent.fromJson(Map<String, dynamic>.from(item)))
        .toList(growable: false);
    final total = (data['total'] as num?)?.toInt();
    final limit = (data['limit'] as num?)?.toInt() ?? 50;
    return SecurityEventPage(
        items: events, page: page, total: total, limit: limit.clamp(1, 100));
  }

  Future<void> resolve(int id,
      {String note = '', PublishSessionScope? session}) async {
    await dio.post('/admin/security/events/$id/resolve',
        data: {'note': note}, options: Options(extra: session?.requestExtra));
  }

  Future<void> markFalsePositive(int id,
      {String note = '', PublishSessionScope? session}) async {
    await dio.post('/admin/security/events/$id/false-positive',
        data: {'note': note}, options: Options(extra: session?.requestExtra));
  }

  /// 用事件记录的来源封禁，并由服务端在同一事务里把仍待处置的事件结案。
  ///
  /// 管理员不持有来源键原值，所以按事件 ID 封禁；[scope] 只能是 'route'
  /// （事件所在接口）或 'account'（账号与凭据链路），时长 15／60／1440 分钟。
  /// 返回事件是否随本次封禁结案（事件已被他人处置时为 false）。
  Future<bool> blockEventSource(
    int eventId, {
    required String scope,
    required int durationMinutes,
    required String reason,
    PublishSessionScope? session,
  }) async {
    final response = await dio.post('/admin/security/events/$eventId/block',
        data: {
          'scope': scope,
          'duration_minutes': durationMinutes,
          'reason': reason,
        },
        options: Options(extra: session?.requestExtra));
    final data = response.data;
    return data is Map && data['event_resolved'] == true;
  }

  /// 安全中心操作记录：结案、误报、封禁、解除封禁，按时间倒序每页 30 条。
  Future<List<SecurityLogEntry>> loadLogs(
      {int page = 1, PublishSessionScope? session}) async {
    final response = await dio.get('/admin/security/logs',
        queryParameters: {'page': page},
        options: Options(extra: session?.requestExtra));
    final items = (response.data as Map)['items'] as List? ?? const [];
    return items
        .whereType<Map>()
        .map((item) =>
            SecurityLogEntry.fromJson(Map<String, dynamic>.from(item)))
        .toList(growable: false);
  }

  /// 创建临时来源封禁。
  ///
  /// [scope] 必须是 'route' / 'account' / 'all' 之一，不允许省略：
  /// 空路由前缀在服务端等价于「对所有高风险接口生效」，校园网、宿舍宽带和
  /// 运营商 CGNAT 出口一旦被整体封禁会连坐一批正常用户，因此默认必须是
  /// 最小作用域 'route'。全部高风险接口需要超级管理员显式二次确认
  /// （[confirmGlobal]），服务端会再次校验这个标志。
  Future<void> createBlock({
    required String sourceKey,
    required int durationMinutes,
    String scope = 'route',
    String routePrefix = '',
    bool confirmGlobal = false,
    String reason = '',
    PublishSessionScope? session,
  }) async {
    await dio.post('/super/security/blocks',
        data: {
          'source_key': sourceKey,
          'duration_minutes': durationMinutes,
          'scope': scope,
          'route_prefix': routePrefix,
          'confirm_global': confirmGlobal,
          'reason': reason,
        },
        options: Options(extra: session?.requestExtra));
  }
}
