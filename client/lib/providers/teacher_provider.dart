import 'dart:async';
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
  final Map<int, int> _detailGenerations = {};

  Timer? _searchDebounce;
  int _searchGeneration = 0;
  Completer<void>? _searchCompleter;
  int? _sessionUserId;
  int _sessionGeneration = 0;

  List<Teacher> get teachers => _teachers;
  List<Teacher> get allTeachers => _allTeachers;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;

  TeacherDetailState detailOf(int teacherId) {
    return _details[teacherId] ?? TeacherDetailState();
  }

  TeacherProvider(this._dio)
      : _interactionService = RatingInteractionService(_dio);

  /// 教师详情含有 myRating、myVote、isOwn 等查看者相关字段。
  /// 切换账号时清除详情与正在进行的请求上下文，避免旧账号数据短暂可见。
  void syncSessionUser(int? userId) {
    if (_sessionUserId == userId) {
      return;
    }
    _sessionUserId = userId;
    _sessionGeneration++;
    _searchGeneration++;
    _detailGenerations.clear();
    _detailRequests.clear();
    _details.clear();
    _teachers = [];
    _allTeachers = [];
    _isLoading = false;
    _errorMessage = null;
    notifyListeners();
  }

  Future<void> loadTeachers({String? query}) {
    _searchDebounce?.cancel();

    final previousCompleter = _searchCompleter;
    if (previousCompleter != null && !previousCompleter.isCompleted) {
      previousCompleter.complete();
    }

    final generation = ++_searchGeneration;
    final sessionGeneration = _sessionGeneration;
    final sessionUserId = _sessionUserId;

    if (query == null || query.trim().isEmpty) {
      _searchCompleter = null;
      return _performLoadTeachers(
        null,
        generation,
        sessionGeneration: sessionGeneration,
        sessionUserId: sessionUserId,
      );
    }

    final completer = Completer<void>();
    _searchCompleter = completer;

    _searchDebounce = Timer(const Duration(milliseconds: 300), () async {
      try {
        if (generation == _searchGeneration) {
          await _performLoadTeachers(
            query.trim(),
            generation,
            sessionGeneration: sessionGeneration,
            sessionUserId: sessionUserId,
          );
        }
      } finally {
        if (!completer.isCompleted) {
          completer.complete();
        }
        if (identical(_searchCompleter, completer)) {
          _searchCompleter = null;
        }
      }
    });

    return completer.future;
  }

  Future<void> _performLoadTeachers(
    String? query,
    int generation, {
    required int sessionGeneration,
    required int? sessionUserId,
  }) async {
    if (!_ownsSession(sessionGeneration, sessionUserId) ||
        generation != _searchGeneration) {
      return;
    }

    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final params = <String, dynamic>{};
      if (query != null && query.isNotEmpty) {
        params['q'] = query;
      }

      final response = await _dio.get(
        '/teachers',
        queryParameters: params.isEmpty ? null : params,
      );

      if (!_ownsSession(sessionGeneration, sessionUserId) ||
          generation != _searchGeneration) {
        return;
      }

      final raw = response.data;
      if (raw is! List) {
        throw const FormatException('教师列表响应不是数组');
      }

      final teachersData = raw
          .whereType<Map>()
          .map(
            (item) => Teacher.fromJson(
              Map<String, dynamic>.from(item),
            ),
          )
          .toList();

      final seen = <int>{};
      _teachers =
          teachersData.where((teacher) => seen.add(teacher.id)).toList();
      _errorMessage = null;
    } catch (error, stackTrace) {
      if (!_ownsSession(sessionGeneration, sessionUserId) ||
          generation != _searchGeneration) {
        return;
      }

      debugPrint('加载教师列表失败 query=$query: $error');
      debugPrintStack(stackTrace: stackTrace);

      _errorMessage = error is DioException ? _parseError(error) : '教师列表数据解析失败';
    } finally {
      if (_ownsSession(sessionGeneration, sessionUserId) &&
          generation == _searchGeneration) {
        _isLoading = false;
        notifyListeners();
      }
    }
  }

  Future<void> loadAllTeachersForSuggestions() async {
    final sessionGeneration = _sessionGeneration;
    final sessionUserId = _sessionUserId;
    try {
      final resp = await _dio.get('/teachers');
      if (resp.statusCode == 200 &&
          _ownsSession(sessionGeneration, sessionUserId)) {
        final seen = <int>{};
        _allTeachers = (resp.data as List)
            .map((j) => Teacher.fromJson(j))
            .where((t) => seen.add(t.id))
            .toList();
      }
    } on DioException catch (e) {
      if (_ownsSession(sessionGeneration, sessionUserId)) {
        _errorMessage = _parseError(e);
      }
    }
  }

  Future<void> loadTeacherDetail(int teacherId, {bool force = false}) {
    final existing = _detailRequests[teacherId];
    if (existing != null && !force) {
      return existing;
    }

    final generation = (_detailGenerations[teacherId] ?? 0) + 1;
    _detailGenerations[teacherId] = generation;
    final sessionGeneration = _sessionGeneration;
    final sessionUserId = _sessionUserId;

    late final Future<void> future;
    future = _loadTeacherDetailInternal(
      teacherId,
      generation: generation,
      sessionGeneration: sessionGeneration,
      sessionUserId: sessionUserId,
    ).whenComplete(() {
      if (identical(_detailRequests[teacherId], future)) {
        _detailRequests.remove(teacherId);
      }
    });

    _detailRequests[teacherId] = future;
    return future;
  }

  bool _ownsTeacherRequest(
    int teacherId,
    int generation,
    int sessionGeneration,
    int? sessionUserId,
  ) {
    return _detailGenerations[teacherId] == generation &&
        _ownsSession(sessionGeneration, sessionUserId);
  }

  Future<void> _loadTeacherDetailInternal(
    int teacherId, {
    required int generation,
    required int sessionGeneration,
    required int? sessionUserId,
  }) async {
    if (!_ownsTeacherRequest(
        teacherId, generation, sessionGeneration, sessionUserId)) {
      return;
    }

    _details[teacherId] =
        detailOf(teacherId).copyWith(isLoading: true, clearError: true);
    notifyListeners();
    try {
      final resp = await _dio.get('/teachers/$teacherId');
      final raw = resp.data;

      if (raw is! Map) {
        throw const FormatException('教师详情响应不是对象');
      }

      final data = Map<String, dynamic>.from(raw);
      final rawTeacher = data['teacher'];
      final rawRatings = data['ratings'];

      if (rawTeacher is! Map) {
        throw const FormatException('教师信息为空');
      }

      final teacher = Teacher.fromJson(
        Map<String, dynamic>.from(rawTeacher),
      );

      final ratings = rawRatings is List
          ? rawRatings
              .whereType<Map>()
              .map(
                (item) => TeacherRating.fromJson(
                  Map<String, dynamic>.from(item),
                ),
              )
              .toList()
          : <TeacherRating>[];

      TeacherRating? myRating;
      if (data['my_rating'] is Map) {
        myRating = TeacherRating.fromJson(
          Map<String, dynamic>.from(data['my_rating'] as Map),
        );
      }

      if (!_ownsTeacherRequest(
          teacherId, generation, sessionGeneration, sessionUserId)) {
        return;
      }
      _details[teacherId] = TeacherDetailState(
        teacher: teacher,
        ratings: ratings,
        myRating: myRating,
        ratingCount: (data['rating_count'] as num?)?.toInt() ?? ratings.length,
        averageStar: (data['average_star'] as num?)?.toDouble() ?? 0,
        isLoading: false,
      );
    } catch (error, stackTrace) {
      debugPrint('教师详情解析或加载失败 teacher=$teacherId: $error');
      debugPrintStack(stackTrace: stackTrace);

      if (!_ownsTeacherRequest(
          teacherId, generation, sessionGeneration, sessionUserId)) {
        return;
      }
      _details[teacherId] = detailOf(teacherId).copyWith(
        isLoading: false,
        errorMessage: error is DioException ? _parseError(error) : '教师数据解析失败',
      );
    } finally {
      if (_ownsTeacherRequest(
          teacherId, generation, sessionGeneration, sessionUserId)) {
        final state = detailOf(teacherId);
        if (state.isLoading) {
          _details[teacherId] = state.copyWith(isLoading: false);
        }
        notifyListeners();
      }
    }
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
    final sessionGeneration = _sessionGeneration;
    final sessionUserId = _sessionUserId;
    try {
      final resp = await _dio.post(
        '/teachers/$teacherId/rate',
        data: {'star': star, 'comment': comment},
      );
      if (resp.statusCode == 200 || resp.statusCode == 201) {
        if (!_ownsSession(sessionGeneration, sessionUserId)) {
          return false;
        }
        await loadTeacherDetail(teacherId, force: true);
        return true;
      }
    } on DioException catch (e) {
      _details[teacherId] =
          detailOf(teacherId).copyWith(errorMessage: _parseError(e));
      notifyListeners();
    }
    return false;
  }

  Future<bool> deleteRating(int ratingId, int teacherId) async {
    final sessionGeneration = _sessionGeneration;
    final sessionUserId = _sessionUserId;
    try {
      final resp = await _dio.delete('/teachers/rating/$ratingId');
      if (resp.statusCode == 200) {
        if (!_ownsSession(sessionGeneration, sessionUserId)) {
          return false;
        }
        await loadTeacherDetail(teacherId, force: true);
        return true;
      }
    } on DioException catch (e) {
      _details[teacherId] =
          detailOf(teacherId).copyWith(errorMessage: _parseError(e));
      notifyListeners();
    }
    return false;
  }

  Future<void> voteRating(int ratingId, int teacherId, String voteType) async {
    final sessionGeneration = _sessionGeneration;
    final sessionUserId = _sessionUserId;
    final result =
        await _interactionService.voteTeacherRating(ratingId, voteType);
    if (result != null && _ownsSession(sessionGeneration, sessionUserId)) {
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
          userAvatar: r.userAvatar,
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
      _details[teacherId] =
          detailOf(teacherId).copyWith(errorMessage: _parseError(e));
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

  bool _ownsSession(int generation, int? userId) {
    return generation == _sessionGeneration && userId == _sessionUserId;
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();

    final completer = _searchCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }

    super.dispose();
  }
}
