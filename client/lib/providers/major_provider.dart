import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import '../services/rating_interaction_service.dart';

class MajorItem {
  final int id;
  final String name;
  final String level;
  final int ratingCount;
  final double averageStar;

  MajorItem({
    required this.id,
    required this.name,
    required this.level,
    this.ratingCount = 0,
    this.averageStar = 0,
  });

  factory MajorItem.fromJson(Map<String, dynamic> j) => MajorItem(
        id: j['id'] ?? 0,
        name: j['name'] ?? '',
        level: j['level'] ?? '',
        ratingCount: j['rating_count'] ?? 0,
        averageStar: (j['average_star'] ?? 0).toDouble(),
      );
}

class MajorRating {
  final int id, majorId, userId, star;
  final String comment, userName, userAvatar;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final int helpfulCount;
  final int unhelpfulCount;
  final String? myVote;
  final bool isOwn;

  MajorRating({
    required this.id,
    required this.majorId,
    required this.userId,
    required this.star,
    required this.comment,
    this.userName = '',
    this.userAvatar = '',
    this.createdAt,
    this.updatedAt,
    this.helpfulCount = 0,
    this.unhelpfulCount = 0,
    this.myVote,
    this.isOwn = false,
  });
  factory MajorRating.fromJson(Map<String, dynamic> j) => MajorRating(
        id: j['id'] ?? 0,
        majorId: j['major_id'] ?? 0,
        userId: j['user_id'] ?? 0,
        star: j['star'] ?? 0,
        comment: j['comment'] ?? '',
        userName: j['user_name'] ?? '',
        userAvatar: j['user_avatar'] ?? '',
        createdAt:
            j['created_at'] != null ? DateTime.tryParse(j['created_at']) : null,
        updatedAt:
            j['updated_at'] != null ? DateTime.tryParse(j['updated_at']) : null,
        helpfulCount: j['helpful_count'] ?? 0,
        unhelpfulCount: j['unhelpful_count'] ?? 0,
        myVote: j['my_vote'],
        isOwn: j['is_own'] ?? false,
      );
}

class MajorProvider extends ChangeNotifier {
  final Dio _dio;
  final RatingInteractionService _interactionService;
  List<MajorItem> _majors = [];
  MajorItem? _selected;
  List<MajorRating> _ratings = [];
  MajorRating? _myRating;
  int _ratingCount = 0;
  double _averageStar = 0;
  bool _isLoading = false;
  String? _errorMessage;
  int? _selectedMajorId;
  int? _sessionUserId;
  int _sessionGeneration = 0;
  int _detailGeneration = 0;

  List<MajorItem> get majors => _majors;
  MajorItem? get selected => _selected;
  List<MajorRating> get ratings => _ratings;
  MajorRating? get myRating => _myRating;
  int get ratingCount => _ratingCount;
  double get averageStar => _averageStar;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;
  int? get selectedMajorId => _selectedMajorId;

  List<int> get starCounts {
    final counts = [0, 0, 0, 0, 0];
    for (var r in _ratings) {
      if (r.star >= 1 && r.star <= 5) {
        counts[r.star - 1]++;
      }
    }
    return counts;
  }

  MajorProvider(this._dio)
      : _interactionService = RatingInteractionService(_dio);

  /// 专业详情响应包含 my_rating、my_vote、is_own 等当前账号字段。
  /// 账号切换时必须丢弃整份详情，并让旧请求失效。
  void syncSessionUser(int? userId) {
    if (_sessionUserId == userId) {
      return;
    }
    _sessionUserId = userId;
    _sessionGeneration++;
    _detailGeneration++;
    _majors = [];
    _isLoading = false;
    _clearDetailState();
    notifyListeners();
  }

  Future<void> loadMajors() async {
    final requestGeneration = _sessionGeneration;
    final requestUserId = _sessionUserId;
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();
    try {
      final r = await _dio.get('/majors');
      if (!_isCurrentSession(requestGeneration, requestUserId)) {
        return;
      }
      _majors = (r.data as List).map((j) => MajorItem.fromJson(j)).toList();
    } catch (_) {
      if (_isCurrentSession(requestGeneration, requestUserId)) {
        _errorMessage = '加载专业列表失败，请稍后重试';
      }
    } finally {
      if (_isCurrentSession(requestGeneration, requestUserId)) {
        _isLoading = false;
        notifyListeners();
      }
    }
  }

  Future<void> loadDetail(int id) async {
    final requestGeneration = _sessionGeneration;
    final requestUserId = _sessionUserId;
    final detailGeneration = ++_detailGeneration;
    _isLoading = true;
    _errorMessage = null;
    _selectedMajorId = id;
    _clearDetailState(keepSelectedId: true);
    notifyListeners();
    try {
      final r = await _dio.get('/majors/$id');
      if (!_ownsDetailRequest(
          id, detailGeneration, requestGeneration, requestUserId)) {
        return;
      }
      _selected = MajorItem.fromJson(r.data['major']);
      _ratings = (r.data['ratings'] as List)
          .map((j) => MajorRating.fromJson(j))
          .toList();
      _myRating = r.data['my_rating'] == null
          ? null
          : MajorRating.fromJson(r.data['my_rating']);
      _ratingCount = r.data['rating_count'] ?? 0;
      _averageStar = (r.data['average_star'] ?? 0).toDouble();
    } catch (_) {
      if (_ownsDetailRequest(
          id, detailGeneration, requestGeneration, requestUserId)) {
        _clearDetailState(keepSelectedId: true);
        _errorMessage = '加载专业详情失败，请稍后重试';
      }
    } finally {
      if (_ownsDetailRequest(
          id, detailGeneration, requestGeneration, requestUserId)) {
        _isLoading = false;
        notifyListeners();
      }
    }
  }

  Future<bool> addMajor(String name, String level) async {
    try {
      await _dio.post('/majors', data: {'name': name, 'level': level});
      await loadMajors();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> deleteMajor(int id) async {
    try {
      await _dio.delete('/majors/$id');
      await loadMajors();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> rate(int id, int star, String comment) async {
    final requestGeneration = _sessionGeneration;
    final requestUserId = _sessionUserId;
    try {
      await _dio.post(
        '/majors/$id/rate',
        data: {'star': star, 'comment': comment},
      );
      if (!_isCurrentSession(requestGeneration, requestUserId)) {
        return false;
      }
      await loadDetail(id);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> deleteRating(int ratingId, int majorId) async {
    final requestGeneration = _sessionGeneration;
    final requestUserId = _sessionUserId;
    try {
      await _dio.delete('/majors/rating/$ratingId');
      if (!_isCurrentSession(requestGeneration, requestUserId)) {
        return false;
      }
      await loadDetail(majorId);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> voteRating(int ratingId, String voteType) async {
    final requestGeneration = _sessionGeneration;
    final requestUserId = _sessionUserId;
    final result =
        await _interactionService.voteMajorRating(ratingId, voteType);
    if (result != null && _isCurrentSession(requestGeneration, requestUserId)) {
      final idx = _ratings.indexWhere((r) => r.id == ratingId);
      if (idx != -1) {
        final r = _ratings[idx];
        _ratings[idx] = MajorRating(
          id: r.id,
          majorId: r.majorId,
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
        notifyListeners();
      }
    }
  }

  Future<bool> reportRating(
      int ratingId, String reasonCode, String reason) async {
    try {
      return await _interactionService.reportRating(
        targetType: 'major_rating',
        targetId: ratingId,
        reasonCode: reasonCode,
        reason: reason,
      );
    } catch (_) {
      return false;
    }
  }

  void _clearDetailState({bool keepSelectedId = false}) {
    _selected = null;
    _ratings = [];
    _myRating = null;
    _ratingCount = 0;
    _averageStar = 0;
    if (!keepSelectedId) {
      _selectedMajorId = null;
    }
  }

  bool _isCurrentSession(int generation, int? userId) {
    return generation == _sessionGeneration && userId == _sessionUserId;
  }

  bool _ownsDetailRequest(
    int majorId,
    int detailGeneration,
    int sessionGeneration,
    int? userId,
  ) {
    return _selectedMajorId == majorId &&
        _detailGeneration == detailGeneration &&
        _isCurrentSession(sessionGeneration, userId);
  }
}
