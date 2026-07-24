import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import '../models/teacher.dart';
import '../services/rating_interaction_service.dart';

class TeacherProvider extends ChangeNotifier {
  final Dio _dio;
  final RatingInteractionService _interactionService;

  List<Teacher> _teachers = [];
  List<Teacher> _allTeachers = [];
  Teacher? _selectedTeacher;
  List<TeacherRating> _ratings = [];
  TeacherRating? _myRating;
  int _ratingCount = 0;
  double _averageStar = 0;
  bool _isLoading = false;
  String? _errorMessage;

  List<Teacher> get teachers => _teachers;

  /// 完整教师列表缓存，供添加授课教师抽屉生成课程候选/重复校验用。
  /// 不受首页搜索框 loadTeachers(query) 过滤影响。
  List<Teacher> get allTeachers => _allTeachers;
  Teacher? get selectedTeacher => _selectedTeacher;
  List<TeacherRating> get ratings => _ratings;
  TeacherRating? get myRating => _myRating;
  int get ratingCount => _ratingCount;
  double get averageStar => _averageStar;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;

  List<int> get starCounts {
    final counts = [0, 0, 0, 0, 0];
    for (var r in _ratings) {
      if (r.star >= 1 && r.star <= 5) {
        counts[r.star - 1]++;
      }
    }
    return counts;
  }

  TeacherProvider(this._dio)
      : _interactionService = RatingInteractionService(_dio);

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

  /// 加载完整教师列表到 allTeachers 缓存（不带搜索词）。
  /// 仅用于添加授课教师抽屉的课程候选/重复校验，不影响 teachers 展示列表，不触发 UI 重建。
  Future<void> loadAllTeachersForSuggestions() async {
    try {
      final resp = await _dio.get('/teachers');
      if (resp.statusCode == 200) {
        final seen = <int>{};
        _allTeachers = (resp.data as List)
            .map((j) => Teacher.fromJson(j))
            .where((t) => seen.add(t.id))
            .toList();
      }
    } on DioException catch (e) {
      _errorMessage = _parseError(e);
    }
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

  Future<void> voteRating(int ratingId, String voteType) async {
    final result =
        await _interactionService.voteTeacherRating(ratingId, voteType);
    if (result != null) {
      final idx = _ratings.indexWhere((r) => r.id == ratingId);
      if (idx != -1) {
        final r = _ratings[idx];
        _ratings[idx] = TeacherRating(
          id: r.id,
          teacherId: r.teacherId,
          userId: r.userId,
          star: r.star,
          comment: r.comment,
          userName: r.userName,
          createdAt: r.createdAt,
          updatedAt: r.updatedAt,
          helpfulCount: result['helpful_count'] ?? 0,
          unhelpfulCount: result['unhelpful_count'] ?? 0,
          myVote: result['my_vote'],
          isOwn: r.isOwn,
        );
        notifyListeners();
      }
    }
  }

  Future<bool> reportRating(
      int ratingId, String reasonCode, String reason) async {
    try {
      return await _interactionService.reportRating(
        targetType: 'teacher_rating',
        targetId: ratingId,
        reasonCode: reasonCode,
        reason: reason,
      );
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
