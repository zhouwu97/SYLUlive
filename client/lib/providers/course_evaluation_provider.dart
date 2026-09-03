import 'package:flutter/foundation.dart';

import '../models/course_evaluation.dart';
import '../services/course_evaluation_service.dart';

/// 课程评价状态容器。
///
/// 会话隔离：每个异步请求开始时记录当前 session generation，
/// 切换账号时递增 generation，回来时若已过期则直接丢弃旧响应，
/// 避免账号 A 的解析结果与"我的内容"被账号 B 读到。
class CourseEvaluationProvider extends ChangeNotifier {
  final CourseEvaluationService? _service;

  int? _sessionAccountId;
  int _accountEpoch = 0;
  int _sessionGeneration = 0;
  bool _hasSessionContext = false;

  // 解析缓存：key 为 "课程名|教师名"。
  final Map<String, CourseEvaluationResolveResult> _resolveCache = {};

  // 最近一次解析错误：key 为 "课程名|教师名"。
  final Map<String, String> _resolveErrors = {};

  final Map<int, CourseEvaluationSubmission> _submissionIndex = {};
  List<CourseEvaluationSubmission> _mine = const [];
  String _mineCursor = '';
  bool _mineHasMore = false;
  bool _isLoadingMine = false;
  bool _isLoadingMoreMine = false;
  String? _mineError;

  List<CourseEvaluationSubmission> _pending = const [];
  String _pendingCursor = '';
  bool _pendingHasMore = false;
  bool _isLoadingPending = false;
  String? _pendingError;

  bool _isSubmitting = false;

  CourseEvaluationProvider(dynamic dio)
      : _service = dio != null ? CourseEvaluationService(dio) : null;

  List<CourseEvaluationSubmission> get mine => _mine;
  bool get isLoadingMine => _isLoadingMine;
  bool get isLoadingMoreMine => _isLoadingMoreMine;
  bool get mineHasMore => _mineHasMore;
  String? get mineError => _mineError;
  bool get isSubmitting => _isSubmitting;

  List<CourseEvaluationSubmission> get pending => _pending;
  bool get isLoadingPending => _isLoadingPending;
  bool get pendingHasMore => _pendingHasMore;
  String? get pendingError => _pendingError;

  bool get hasService => _service != null;

  /// 账号切换或退出登录时调用。清空解析缓存与"我的内容"。
  void syncSessionUser(int? accountId, [int accountEpoch = 0]) {
    final normalized = accountId != null && accountId > 0 ? accountId : null;
    if (_hasSessionContext &&
        _sessionAccountId == normalized &&
        _accountEpoch == accountEpoch) {
      return;
    }
    _hasSessionContext = true;
    _sessionAccountId = normalized;
    _accountEpoch = accountEpoch;
    _sessionGeneration++;

    _resolveCache.clear();
    _resolveErrors.clear();
    _submissionIndex.clear();
    _mine = const [];
    _mineCursor = '';
    _mineHasMore = false;
    _isLoadingMine = false;
    _isLoadingMoreMine = false;
    _mineError = null;

    _pending = const [];
    _pendingCursor = '';
    _pendingHasMore = false;
    _isLoadingPending = false;
    _pendingError = null;
    _isSubmitting = false;
    notifyListeners();
  }

  bool _isStale(int generation) => generation != _sessionGeneration;

  static String _resolveKey(String courseName, String teacherName) =>
      '${courseName.trim()}|${teacherName.trim()}';

  /// 读取解析缓存（同步）。未命中返回 null，由调用方决定是否发起请求。
  CourseEvaluationResolveResult? resolveCacheFor(
    String courseName,
    String teacherName,
  ) =>
      _resolveCache[_resolveKey(courseName, teacherName)];

  /// 解析课程名与教师名。命中缓存直接返回。
  Future<CourseEvaluationResolveResult?> resolveForCourse(
    String courseName,
    String teacherName,
  ) async {
    final service = _service;
    if (service == null) return null;
    final key = _resolveKey(courseName, teacherName);
    final cached = _resolveCache[key];
    if (cached != null) return cached;

    final generation = _sessionGeneration;
    try {
      final result = await service.resolve(
        courseName: courseName,
        teacherName: teacherName,
      );
      if (_isStale(generation)) return null;
      _resolveCache[key] = result;
      _resolveErrors.remove(key);
      if (result.submission != null) {
        _indexSubmission(result.submission!);
      }
      notifyListeners();
      return result;
    } on CourseEvaluationException catch (e) {
      if (_isStale(generation)) return null;
      _resolveErrors[key] = e.message;
      notifyListeners();
      return null;
    } catch (_) {
      if (_isStale(generation)) return null;
      _resolveErrors[key] = '课程评价服务暂不可用';
      notifyListeners();
      return null;
    }
  }

  String? resolveErrorFor(String courseName, String teacherName) =>
      _resolveErrors[_resolveKey(courseName, teacherName)];

  void _indexSubmission(CourseEvaluationSubmission submission) {
    _submissionIndex[submission.id] = submission;
    final index = _mine.indexWhere((item) => item.id == submission.id);
    if (index >= 0) {
      final next = List<CourseEvaluationSubmission>.from(_mine);
      next[index] = submission;
      _mine = next;
    }
  }

  /// 按 ID 查找提交记录。跨模块（通知深链、我的内容定位）使用同一份索引。
  CourseEvaluationSubmission? submissionById(int id) =>
      _submissionIndex[id] ??
      (_mine.where((item) => item.id == id).isNotEmpty
          ? _mine.firstWhere((item) => item.id == id)
          : null);

  /// 提交新评价。
  Future<CourseEvaluationSubmission?> submit({
    required String courseName,
    required String teacherName,
    required int star,
    required String comment,
    int? courseSubjectId,
    int? teacherId,
  }) async {
    final service = _service;
    if (service == null) return null;
    final generation = _sessionGeneration;
    _isSubmitting = true;
    notifyListeners();
    try {
      final submission = await service.submit(
        courseName: courseName,
        teacherName: teacherName,
        star: star,
        comment: comment,
        courseSubjectId: courseSubjectId,
        teacherId: teacherId,
      );
      if (_isStale(generation)) return null;
      _isSubmitting = false;
      _resolveCache.remove(_resolveKey(courseName, teacherName));
      _resolveErrors.remove(_resolveKey(courseName, teacherName));
      _indexSubmission(submission);
      if (!_mine.any((item) => item.id == submission.id)) {
        _mine = [submission, ..._mine];
      }
      notifyListeners();
      return submission;
    } on CourseEvaluationException catch (_) {
      if (_isStale(generation)) return null;
      _isSubmitting = false;
      notifyListeners();
      rethrow;
    } catch (_) {
      if (_isStale(generation)) return null;
      _isSubmitting = false;
      notifyListeners();
      rethrow;
    }
  }

  /// 编辑既有记录。三个状态均可打开同一表单编辑原记录。
  Future<CourseEvaluationSubmission?> update({
    required int id,
    required String courseName,
    required String teacherName,
    required int star,
    required String comment,
    required int revision,
    int? courseSubjectId,
    int? teacherId,
  }) async {
    final service = _service;
    if (service == null) return null;
    final generation = _sessionGeneration;
    _isSubmitting = true;
    notifyListeners();
    try {
      final submission = await service.update(
        id: id,
        courseName: courseName,
        teacherName: teacherName,
        star: star,
        comment: comment,
        revision: revision,
        courseSubjectId: courseSubjectId,
        teacherId: teacherId,
      );
      if (_isStale(generation)) return null;
      _isSubmitting = false;
      _resolveCache.remove(_resolveKey(courseName, teacherName));
      _indexSubmission(submission);
      notifyListeners();
      return submission;
    } catch (_) {
      if (_isStale(generation)) return null;
      _isSubmitting = false;
      notifyListeners();
      rethrow;
    }
  }

  /// 加载"我的内容 → 学科评价"。cursor 分页。
  Future<void> loadMine({bool refresh = false}) async {
    final service = _service;
    if (service == null) return;
    if (_isLoadingMine) return;
    final generation = _sessionGeneration;
    _isLoadingMine = true;
    if (refresh) {
      _mineCursor = '';
      _mineHasMore = false;
    }
    _mineError = null;
    notifyListeners();
    try {
      final page = await service.listMine(
        cursor: refresh ? null : (_mineCursor.isEmpty ? null : _mineCursor),
      );
      if (_isStale(generation)) return;
      _mine = page.items;
      _mineCursor = page.nextCursor;
      _mineHasMore = page.hasMore;
      _isLoadingMine = false;
      _mineError = null;
      for (final item in page.items) {
        _submissionIndex[item.id] = item;
      }
      notifyListeners();
    } on CourseEvaluationException catch (e) {
      if (_isStale(generation)) return;
      _isLoadingMine = false;
      _mineError = e.message;
      notifyListeners();
    } catch (_) {
      if (_isStale(generation)) return;
      _isLoadingMine = false;
      _mineError = '课程评价服务暂不可用';
      notifyListeners();
    }
  }

  /// 加载下一页"我的内容"。
  Future<void> loadMoreMine() async {
    final service = _service;
    if (service == null || _isLoadingMoreMine || !_mineHasMore) return;
    final generation = _sessionGeneration;
    _isLoadingMoreMine = true;
    notifyListeners();
    try {
      final page = await service.listMine(cursor: _mineCursor);
      if (_isStale(generation)) return;
      _isLoadingMoreMine = false;
      _mine = [..._mine, ...page.items];
      _mineCursor = page.nextCursor;
      _mineHasMore = page.hasMore;
      for (final item in page.items) {
        _submissionIndex[item.id] = item;
      }
      notifyListeners();
    } catch (_) {
      if (_isStale(generation)) return;
      _isLoadingMoreMine = false;
      notifyListeners();
    }
  }

  /// 管理员加载待审核列表。
  Future<void> loadPending({bool refresh = false}) async {
    final service = _service;
    if (service == null) return;
    final generation = _sessionGeneration;
    _isLoadingPending = true;
    if (refresh) {
      _pendingCursor = '';
      _pendingHasMore = false;
      _pending = const [];
    }
    _pendingError = null;
    notifyListeners();
    try {
      final page = await service.listPending(
        cursor: refresh ? null : (_pendingCursor.isEmpty ? null : _pendingCursor),
      );
      if (_isStale(generation)) return;
      _pending = page.items;
      _pendingCursor = page.nextCursor;
      _pendingHasMore = page.hasMore;
      _isLoadingPending = false;
      _pendingError = null;
      notifyListeners();
    } on CourseEvaluationException catch (e) {
      if (_isStale(generation)) return;
      _isLoadingPending = false;
      _pendingError = e.message;
      notifyListeners();
    } catch (_) {
      if (_isStale(generation)) return;
      _isLoadingPending = false;
      _pendingError = '课程评价服务暂不可用';
      notifyListeners();
    }
  }

  /// 管理员审核通过。成功返回更新的记录，409 由调用方捕获后保留任务。
  Future<CourseEvaluationSubmission?> approve({
    required int id,
    required int revision,
  }) async {
    final service = _service;
    if (service == null) return null;
    final generation = _sessionGeneration;
    final submission = await service.approve(id: id, revision: revision);
    if (_isStale(generation)) return null;
    _pending = _pending.where((item) => item.id != id).toList();
    _submissionIndex[id] = submission;
    notifyListeners();
    return submission;
  }

  /// 管理员驳回。
  Future<CourseEvaluationSubmission?> reject({
    required int id,
    required int revision,
    required String reason,
  }) async {
    final service = _service;
    if (service == null) return null;
    final generation = _sessionGeneration;
    final submission = await service.reject(
      id: id,
      revision: revision,
      reason: reason,
    );
    if (_isStale(generation)) return null;
    _pending = _pending.where((item) => item.id != id).toList();
    _submissionIndex[id] = submission;
    notifyListeners();
    return submission;
  }

  /// 加载学科详情（含已审核教师），供评价表单在切换学科时取教师候选。
  Future<CourseSubjectDetail?> loadSubjectDetail(int subjectId) async {
    final service = _service;
    if (service == null) return null;
    final generation = _sessionGeneration;
    try {
      final detail = await service.getSubject(subjectId);
      if (_isStale(generation)) return null;
      return detail;
    } catch (_) {
      return null;
    }
  }

  /// 本地移除待审核任务（审核成功后只移除对应任务）。
  void removePendingLocally(int id) {
    _pending = _pending.where((item) => item.id != id).toList();
    notifyListeners();
  }
}
