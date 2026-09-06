import 'package:flutter/foundation.dart';

import '../models/course_evaluation.dart';
import '../services/course_evaluation_service.dart';

/// 标准学科状态容器。
///
/// 学科列表与详情均按服务端返回的学科 ID 加载与传递；
/// 客户端不用教师文本重新分组，也不通过包含关系合并 A1/A2。
/// 学科榜为公开数据，不做账号隔离，但刷新结果仍受请求代际保护。
class CourseSubjectProvider extends ChangeNotifier {
  final CourseEvaluationService? _service;

  List<CourseSubject> _subjects = const [];
  bool _isLoading = false;
  String? _error;

  /// 学科详情缓存：按学科 ID 索引。
  final Map<int, CourseSubjectDetail> _detailCache = {};

  CourseSubjectProvider(dynamic dio)
      : _service = dio != null ? CourseEvaluationService(dio) : null;

  List<CourseSubject> get subjects => _subjects;
  bool get isLoading => _isLoading;
  String? get error => _error;
  bool get hasService => _service != null;

  CourseSubjectDetail? detailById(int id) => _detailCache[id];

  /// 加载公开学科列表。公开接口只返回已审核学科与已审核教师。
  Future<void> loadSubjects({bool force = false}) async {
    final service = _service;
    if (service == null) return;
    if (_isLoading) return;
    // 已有数据且未强制刷新时跳过，避免学科榜重复请求。
    if (!force && _subjects.isNotEmpty) return;
    _isLoading = true;
    _error = null;
    notifyListeners();
    try {
      final subjects = await service.listSubjects();
      _subjects = subjects;
      _isLoading = false;
      _error = null;
      notifyListeners();
    } on CourseEvaluationException catch (e) {
      _isLoading = false;
      _error = e.message;
      notifyListeners();
    } catch (_) {
      _isLoading = false;
      _error = '学科榜服务暂不可用';
      notifyListeners();
    }
  }

  /// 按学科 ID 加载详情（含已审核教师）。命中缓存直接返回。
  Future<CourseSubjectDetail?> loadSubjectDetail(
    int subjectId, {
    bool force = false,
  }) async {
    final service = _service;
    if (service == null || subjectId <= 0) return null;
    if (!force) {
      final cached = _detailCache[subjectId];
      if (cached != null) return cached;
    }
    try {
      final detail = await service.getSubject(subjectId);
      _detailCache[subjectId] = detail;
      notifyListeners();
      return detail;
    } catch (_) {
      return null;
    }
  }
}
