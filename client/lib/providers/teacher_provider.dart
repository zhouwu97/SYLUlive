import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import '../models/teacher.dart';

class TeacherProvider extends ChangeNotifier {
  final Dio _dio;

  List<Teacher> _teachers = [];
  Teacher? _selectedTeacher;
  List<TeacherRating> _ratings = [];
  TeacherRating? _myRating;
  int _ratingCount = 0;
  double _averageStar = 0;
  bool _isLoading = false;
  String? _errorMessage;

  List<Teacher> get teachers => _teachers;
  Teacher? get selectedTeacher => _selectedTeacher;
  List<TeacherRating> get ratings => _ratings;
  TeacherRating? get myRating => _myRating;
  int get ratingCount => _ratingCount;
  double get averageStar => _averageStar;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;

  TeacherProvider(this._dio);

  /// 获取教师列表（支持搜索）
  Future<void> loadTeachers({String? query}) async {
    _isLoading = true;
    notifyListeners();
    try {
      final params = <String, dynamic>{};
      if (query != null && query.isNotEmpty) params['q'] = query;
      final resp = await _dio.get(
        '/teachers',
        queryParameters: params.isEmpty ? null : params,
      );
      if (resp.statusCode == 200) {
        final seen = <int>{};
        _teachers = (resp.data as List)
            .map((j) => Teacher.fromJson(j))
            .where((t) => seen.add(t.id))
            .toList();
      }
    } on DioException catch (e) {
      _errorMessage = _parseError(e);
    }
    _isLoading = false;
    notifyListeners();
  }

  /// 获取教师详情（含评价列表）
  Future<void> loadTeacherDetail(int teacherId) async {
    _isLoading = true;
    notifyListeners();
    try {
      final resp = await _dio.get('/teachers/$teacherId');
      if (resp.statusCode == 200) {
        final data = resp.data;
        _selectedTeacher = Teacher.fromJson(data['teacher']);
        _ratings = (data['ratings'] as List)
            .map((j) => TeacherRating.fromJson(j))
            .toList();
        _ratingCount = data['rating_count'] ?? 0;
        _averageStar = (data['average_star'] ?? 0).toDouble();
        if (data['my_rating'] != null) {
          _myRating = TeacherRating.fromJson(data['my_rating']);
        } else {
          _myRating = null;
        }
      }
    } on DioException catch (e) {
      _errorMessage = _parseError(e);
    }
    _isLoading = false;
    notifyListeners();
  }

  /// 添加教师
  Future<bool> addTeacher(String name, String course) async {
    try {
      final resp = await _dio.post(
        '/teachers',
        data: {'name': name, 'course': course},
      );
      if (resp.statusCode == 201) {
        await loadTeachers(); // 刷新列表
        return true;
      }
    } on DioException catch (e) {
      _errorMessage = _parseError(e);
      notifyListeners();
    }
    return false;
  }

  /// 评价教师（创建或更新）
  Future<bool> rateTeacher(int teacherId, int star, String comment) async {
    try {
      final resp = await _dio.post(
        '/teachers/$teacherId/rate',
        data: {'star': star, 'comment': comment},
      );
      if (resp.statusCode == 200 || resp.statusCode == 201) {
        await loadTeacherDetail(teacherId);
        return true;
      }
    } on DioException catch (e) {
      _errorMessage = _parseError(e);
      notifyListeners();
    }
    return false;
  }

  /// 删除自己的评价
  Future<bool> deleteRating(int ratingId, int teacherId) async {
    try {
      final resp = await _dio.delete('/teachers/rating/$ratingId');
      if (resp.statusCode == 200) {
        await loadTeacherDetail(teacherId);
        return true;
      }
    } on DioException catch (e) {
      _errorMessage = _parseError(e);
      notifyListeners();
    }
    return false;
  }

  /// 举报评价
  Future<bool> reportRating(int ratingId) async {
    try {
      await _dio.post('/teachers/rating/$ratingId/report');
      return true;
    } on DioException catch (e) {
      _errorMessage = _parseError(e);
      notifyListeners();
    }
    return false;
  }

  String _parseError(DioException e) {
    if (e.response?.data is Map && e.response?.data['error'] != null) {
      return e.response!.data['error'];
    }
    return '网络异常';
  }
}
