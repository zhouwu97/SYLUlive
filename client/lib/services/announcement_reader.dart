import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../config/api_constants.dart';
import '../models/announcement.dart';
import '../providers/auth_provider.dart';

Future<List<Announcement>> readAnnouncements(Dio dio) => _read(dio, '');

Future<List<Announcement>> readUnreadAnnouncements(AuthProvider auth) async {
  if (!auth.isLoggedIn) return [];
  try {
    return await _read(auth.dio, '/unread');
  } catch (e) {
    debugPrint('加载未读公告失败: $e');
    return [];
  }
}

Future<List<Announcement>> _read(Dio dio, String suffix) async {
  Response<dynamic> response;
  try {
    response = await dio.get('${ApiConstants.noticesPath}$suffix');
  } on DioException catch (e) {
    // 仅在服务端缺少新版路由时尝试旧公告路径。
    if (e.response?.statusCode != 404) rethrow;
    response = await dio.get('/announcements$suffix');
  }
  if (response.statusCode != 200 || response.data is! List) return [];
  return (response.data as List)
      .map((item) => Announcement.fromJson(item))
      .toList()
    ..sort(Announcement.compareForDisplay);
}
