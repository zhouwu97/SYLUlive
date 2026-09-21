import 'package:dio/dio.dart';

import '../models/security_event.dart';

class AdminSecurityService {
  final Dio dio;

  const AdminSecurityService(this.dio);

  Future<SecurityOverview> loadOverview({String range = '24h'}) async {
    final response = await dio
        .get('/admin/security/overview', queryParameters: {'range': range});
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
  }) async {
    final response = await dio.get('/admin/security/events', queryParameters: {
      'severity': severity,
      'status': status,
      'actionable': actionable,
      'page': page,
      'limit': 50,
    });
    final data = Map<String, dynamic>.from(response.data as Map);
    final items = data['items'] as List? ?? const [];
    return items
        .whereType<Map>()
        .map((item) => SecurityEvent.fromJson(Map<String, dynamic>.from(item)))
        .toList(growable: false);
  }

  Future<void> resolve(int id, {String note = ''}) async {
    await dio.post('/admin/security/events/$id/resolve', data: {'note': note});
  }

  Future<void> markFalsePositive(int id, {String note = ''}) async {
    await dio.post('/admin/security/events/$id/false-positive',
        data: {'note': note});
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
  }) async {
    await dio.post('/super/security/blocks', data: {
      'source_key': sourceKey,
      'duration_minutes': durationMinutes,
      'scope': scope,
      'route_prefix': routePrefix,
      'confirm_global': confirmGlobal,
      'reason': reason,
    });
  }
}
