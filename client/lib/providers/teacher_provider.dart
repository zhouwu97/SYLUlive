import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import '../models/teacher.dart';
import '../services/rating_interaction_service.dart';

class TeacherDetailState {
  final Teacher? teacher;
  final List<TeacherRating> ratings;
  final TeacherRating? myRating;
  final int ratingCount;
  final double averageStar;
  final bool isLoading;
  final String? errorMessage;

  TeacherDetailState({
    this.teacher,
    this.ratings = const [],
    this.myRating,
    this.ratingCount = 0,
    this.averageStar = 0.0,
    this.isLoading = false,
    this.errorMessage,
  });

  TeacherDetailState copyWith({
    Teacher? teacher,
    List<TeacherRating>? ratings,
    TeacherRating? myRating,
    int? ratingCount,
    double? averageStar,
    bool? isLoading,
    String? errorMessage,
    bool clearError = false,
  }) {
    return TeacherDetailState(
      teacher: teacher ?? this.teacher,
      ratings: ratings ?? this.ratings,
      myRating: myRating ?? this.myRating,
      ratingCount: ratingCount ?? this.ratingCount,
      averageStar: averageStar ?? this.averageStar,
      isLoading: isLoading ?? this.isLoading,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }

  List<int> get starCounts {
    final counts = [0, 0, 0, 0, 0];
    for (var r in ratings) {
      if (r.star >= 1 && r.star <= 5) {
        counts[r.star - 1]++;
      }
    }
    return counts;
  }
}

class TeacherProvider extends ChangeNotifier {
  final Dio _dio;
  final RatingInteractionService _interactionService;

  List<Teacher> _teachers = [];
  List<Teacher> _allTeachers = [];
  bool _isLoading = false;
  String? _errorMessage;

  final Map<int, TeacherDetailState> _details = {};
  final Map<int, Future<void>> _detailRequests = {};

  List<Teacher> get teachers => _teachers;
  List<Teacher> get allTeachers => _allTeachers;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;

  TeacherDetailState detailOf(int teacherId) {
    return _details[teacherId] ?? TeacherDetailState();
  }

  TeacherProvider(this._dio)
      : _interactionService = RatingInteractionService(_dio);

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

  Future<void> loadTeacherDetail(int teacherId, {bool force = false}) {
    if (!force) {
      final existing = _detailRequests[teacherId];
      if (existing != null) return existing;
    }

    final future = _loadTeacherDetailInternal(teacherId, force: force)
        .whenComplete(() {
      _detailRequests.remove(teacherId);
    });

    _detailRequests[teacherId] = future;
    return future;
  }

  Future<void> _loadTeacherDetailInternal(int teacherId, {bool force = false}) async {
    _details[teacherId] = detailOf(teacherId).copyWith(isLoading: true, clearError: true);
    notifyListeners();
    try {
      final resp = await _dio.get('/teachers/$teacherId');
      if (resp.statusCode == 200) {
        final data = resp.data;
        _details[teacherId] = _details[teacherId]!.copyWith(
          teacher: Teacher.fromJson(data['teacher']),
          ratings: (data['ratings'] as List)
              .map((j) => TeacherRating.fromJson(j))
              .toList(),
          ratingCount: data['rating_count'] ?? 0,
          averageStar: (data['average_star'] ?? 0).toDouble(),
          myRating: data['my_rating'] != null
              ? TeacherRating.fromJson(data['my_rating'])
              : null,
          isLoading: false,
          clearError: true,
        );
      } else {
        _details[teacherId] = _details[teacherId]!.copyWith(
            isLoading: false, errorMessage: '加载失败');
      }
    } on DioException catch (e) {
      _details[teacherId] = _details[teacherId]!.copyWith(
          isLoading: false, errorMessage: _parseError(e));
    }
    notifyListeners();
  }

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

  Future<bool> rateTeacher(int teacherId, int star, String comment) async {
    try {
      final resp = await _dio.post(
        '/teachers/$teacherId/rate',
        data: {'star': star, 'comment': comment},
      );
      if (resp.statusCode == 200 || resp.statusCode == 201) {
        await loadTeacherDetail(teacherId, force: true);
        return true;
      }
    } on DioException catch (e) {
      _details[teacherId] = detailOf(teacherId).copyWith(errorMessage: _parseError(e));
      notifyListeners();
    }
    return false;
  }

  Future<bool> deleteRating(int ratingId, int teacherId) async {
    try {
      final resp = await _dio.delete('/teachers/rating/$ratingId');
      if (resp.statusCode == 200) {
        await loadTeacherDetail(teacherId, force: true);
        return true;
      }
    } on DioException catch (e) {
      _details[teacherId] = detailOf(teacherId).copyWith(errorMessage: _parseError(e));
      notifyListeners();
    }
    return false;
  }

  Future<void> voteRating(int ratingId, int teacherId, String voteType) async {
    final result =
        await _interactionService.voteTeacherRating(ratingId, voteType);
    if (result != null) {
      final state = detailOf(teacherId);
      final newRatings = List<TeacherRating>.of(state.ratings);
      final idx = newRatings.indexWhere((r) => r.id == ratingId);
      if (idx != -1) {
        final r = newRatings[idx];
        newRatings[idx] = TeacherRating(
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
        _details[teacherId] = state.copyWith(ratings: newRatings);
        notifyListeners();
      }
    }
  }

  Future<bool> reportRating(
      int ratingId, int teacherId, String reasonCode, String reason) async {
    try {
      return await _interactionService.reportRating(
        targetType: 'teacher_rating',
        targetId: ratingId,
        reasonCode: reasonCode,
        reason: reason,
      );
    } on DioException catch (e) {
      _details[teacherId] = detailOf(teacherId).copyWith(errorMessage: _parseError(e));
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
