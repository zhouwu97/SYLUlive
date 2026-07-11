import 'package:dio/dio.dart';

import '../models/team_recruitment.dart';
import '../models/water_team.dart';

/// 组队大厅接口；不再通过帖子接口或水帖标签访问组队业务。
class TeamRecruitmentService {
  final Dio _dio;

  TeamRecruitmentService(this._dio);

  Future<TeamRecruitmentPage> list({
    String? category,
    String? status,
    String? keyword,
    String? role,
    String sort = 'recommended',
    bool availableOnly = false,
    int page = 1,
    int limit = 20,
    CancelToken? cancelToken,
  }) async {
    final response = await _dio.get('/team/recruitments',
        queryParameters: {
          if (category != null && category.isNotEmpty) 'category': category,
          if (status != null && status.isNotEmpty) 'status': status,
          if (keyword != null && keyword.isNotEmpty) 'keyword': keyword,
          if (role != null && role.isNotEmpty) 'role': role,
          'sort': sort,
          if (availableOnly) 'available_only': true,
          'page': page,
          'limit': limit,
        },
        cancelToken: cancelToken);
    return TeamRecruitmentPage.fromJson(_map(response.data));
  }

  Future<TeamRecruitment> detail(int recruitmentId) async {
    final response = await _dio.get('/team/recruitments/$recruitmentId');
    return TeamRecruitment.fromJson(_map(response.data));
  }

  Future<TeamRecruitment> create({
    required String category,
    required String title,
    required String description,
    required int neededCount,
    required List<String> roles,
    DateTime? deadline,
    List<int> imageFileIds = const [],
  }) async {
    final response = await _dio.post('/team/recruitments', data: {
      'category': category,
      'title': title,
      'description': description,
      'needed_count': neededCount,
      'roles': roles,
      if (deadline != null) 'deadline': deadline.toUtc().toIso8601String(),
      'image_file_ids': imageFileIds,
    });
    final data = _map(response.data);
    final recruitment = data['recruitment'];
    return TeamRecruitment.fromJson(
      recruitment is Map ? recruitment.cast<String, dynamic>() : data,
    );
  }

  Future<TeamRecruitment> update({
    required int recruitmentId,
    required String category,
    required String title,
    required String description,
    required int neededCount,
    required List<String> roles,
    DateTime? deadline,
    List<int> imageFileIds = const [],
  }) async {
    final response =
        await _dio.patch('/team/recruitments/$recruitmentId', data: {
      'category': category,
      'title': title,
      'description': description,
      'needed_count': neededCount,
      'roles': roles,
      'deadline': deadline?.toUtc().toIso8601String() ?? '',
      'image_file_ids': imageFileIds,
    });
    final data = _map(response.data);
    final recruitment = data['recruitment'];
    return TeamRecruitment.fromJson(
      recruitment is Map ? recruitment.cast<String, dynamic>() : data,
    );
  }

  Future<List<TeamRecruitment>> mine() async {
    final response = await _dio
        .get('/team/recruitments/mine', queryParameters: {'limit': 50});
    return _items(response.data);
  }

  Future<WaterTeamApplication> apply({
    required int recruitmentId,
    required String message,
    String availability = '',
  }) async {
    final response =
        await _dio.post('/team/recruitments/$recruitmentId/apply', data: {
      'message': message,
      'availability': availability,
    });
    return WaterTeamApplication.fromJson(_map(response.data));
  }

  Future<List<WaterTeamApplication>> myApplications() async {
    final response = await _dio.get('/team/my_applications');
    return _applications(response.data);
  }

  Future<List<WaterTeamApplication>> applications(int recruitmentId) async {
    final response =
        await _dio.get('/team/recruitments/$recruitmentId/applications');
    return _applications(response.data);
  }

  Future<void> cancel(int applicationId) =>
      _dio.post('/team/applications/$applicationId/cancel');
  Future<void> accept(int applicationId, {String reply = ''}) => _dio
      .post('/team/applications/$applicationId/accept', data: {'reply': reply});
  Future<void> reject(int applicationId, {String reply = ''}) => _dio
      .post('/team/applications/$applicationId/reject', data: {'reply': reply});
  Future<void> updateStatus(int recruitmentId, String status) =>
      _dio.patch('/team/recruitments/$recruitmentId/status',
          data: {'status': status});

  static Map<String, dynamic> _map(dynamic value) =>
      value is Map ? value.cast<String, dynamic>() : <String, dynamic>{};

  static List<TeamRecruitment> _items(dynamic value) {
    final data = _map(value);
    final items = data['items'] is List ? data['items'] as List : const [];
    return items
        .whereType<Map>()
        .map((item) => TeamRecruitment.fromJson(item.cast<String, dynamic>()))
        .toList(growable: false);
  }

  static List<WaterTeamApplication> _applications(dynamic value) {
    final data = value is Map ? value['applications'] ?? value['data'] : value;
    if (data is! List) return const [];
    return data
        .whereType<Map>()
        .map((item) =>
            WaterTeamApplication.fromJson(item.cast<String, dynamic>()))
        .toList(growable: false);
  }
}

/// 服务端分页响应，排序和页码均以服务端为准。
class TeamRecruitmentPage {
  final List<TeamRecruitment> items;
  final int total;
  final int page;
  final int limit;
  final bool hasMore;

  const TeamRecruitmentPage({
    required this.items,
    required this.total,
    required this.page,
    required this.limit,
    required this.hasMore,
  });

  factory TeamRecruitmentPage.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'] is List ? json['items'] as List : const [];
    return TeamRecruitmentPage(
      items: rawItems
          .whereType<Map>()
          .map((item) => TeamRecruitment.fromJson(item.cast<String, dynamic>()))
          .toList(growable: false),
      total: (json['total'] as num?)?.toInt() ?? 0,
      page: (json['page'] as num?)?.toInt() ?? 1,
      limit: (json['limit'] as num?)?.toInt() ??
          (json['page_size'] as num?)?.toInt() ??
          20,
      hasMore: json['has_more'] == true,
    );
  }
}
