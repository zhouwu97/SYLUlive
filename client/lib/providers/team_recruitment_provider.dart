import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';

import '../models/team_recruitment.dart';
import '../models/water_team.dart';
import '../services/team_recruitment_service.dart';
import '../services/idempotency_key.dart';
import '../utils/public_image_compressor.dart';

/// 组队大厅首屏状态，网络失败不能伪装成空列表。
enum TeamFeedViewState {
  initial,
  loading,
  content,
  empty,
  unavailable,
  networkError,
  serverError,
}

/// 组队操作的统一返回值，避免用 null 混淆网络、权限与校验失败。
class TeamOperationResult<T> {
  final T? data;
  final String? errorMessage;
  final TeamErrorType errorType;
  const TeamOperationResult.success(this.data)
      : errorMessage = null,
        errorType = TeamErrorType.none;
  const TeamOperationResult.failure(this.errorMessage, this.errorType)
      : data = null;
  bool get success => errorType == TeamErrorType.none;
}

enum TeamErrorType {
  none,
  unauthorized,
  validation,
  unavailable,
  network,
  server
}

/// 组队大厅独立状态；不会刷新或修改普通水帖的信息流缓存。
class TeamRecruitmentProvider extends ChangeNotifier {
  final Dio _dio;
  final PublicImageCompressor _publicImageCompressor = PublicImageCompressor();
  late final TeamRecruitmentService _service = TeamRecruitmentService(_dio);

  TeamRecruitmentProvider(this._dio);

  List<TeamRecruitment> publicItems = const [];
  List<TeamRecruitment> myCreated = const [];
  List<WaterTeamApplication> myApplications = const [];
  final Map<int, List<WaterTeamApplication>> _applications = {};
  TeamFeedViewState viewState = TeamFeedViewState.initial;
  bool isLoadingPublic = false;
  bool isLoadingMore = false;
  bool isRefreshing = false;
  bool isLoadingMine = false;
  bool isCreating = false;
  final Set<int> updatingIds = {};
  String? publicError;
  String? refreshWarning;
  int? publicStatusCode;
  String? mineError;
  final Set<int> applyingIds = {};
  final Set<int> closingIds = {};
  final Set<int> deletingIds = {};
  final Set<int> reviewingApplicationIds = {};
  final Set<int> loadingApplicationIds = {};
  final Map<int, String> applicationErrors = {};
  final Map<String, String> _idempotencyKeys = <String, String>{};

  int publicPage = 1;
  int publicTotal = 0;
  bool publicHasMore = true;
  String currentKeyword = '';
  String currentSort = 'recommended';
  String? currentCategory;
  String? currentStatus = 'recruiting';
  bool currentAvailableOnly = false;
  int _publicRequestVersion = 0;
  int _mineRequestVersion = 0;
  CancelToken? _publicCancelToken;
  CancelToken? _mineCancelToken;
  int? _sessionUserId;
  int _sessionVersion = 0;

  int get sessionVersion => _sessionVersion;

  /// 登录用户变化时清空所有带账号语义的数据，并使旧请求结果失效。
  void syncSessionUser(int? userId) {
    if (_sessionUserId == userId) return;
    _sessionUserId = userId;
    _sessionVersion++;
    _publicRequestVersion++;
    _mineRequestVersion++;
    _publicCancelToken?.cancel('登录用户已变化');
    _mineCancelToken?.cancel('登录用户已变化');
    publicItems = const [];
    myCreated = const [];
    myApplications = const [];
    _applications.clear();
    viewState = TeamFeedViewState.initial;
    isLoadingPublic = false;
    isLoadingMore = false;
    isRefreshing = false;
    isLoadingMine = false;
    isCreating = false;
    publicError = null;
    refreshWarning = null;
    mineError = null;
    applyingIds.clear();
    closingIds.clear();
    deletingIds.clear();
    reviewingApplicationIds.clear();
    updatingIds.clear();
    loadingApplicationIds.clear();
    applicationErrors.clear();
    _idempotencyKeys.clear();
    notifyListeners();
  }

  Future<void> loadPublic(
      {String? category,
      String? status,
      String? keyword,
      String? sort,
      bool? availableOnly,
      bool force = false}) async {
    currentCategory = category;
    currentStatus = status;
    currentKeyword = keyword?.trim() ?? '';
    currentSort = sort ?? currentSort;
    currentAvailableOnly = availableOnly ?? currentAvailableOnly;
    await refreshPublic(force: force);
  }

  Future<void> refreshPublic({bool force = false}) async {
    final requestVersion = ++_publicRequestVersion;
    _publicCancelToken?.cancel('已由最新筛选替代');
    final cancelToken = _publicCancelToken = CancelToken();
    final hasContent = publicItems.isNotEmpty;
    isLoadingPublic = true;
    // 旧分页请求会通过版本号丢弃结果，新筛选必须同步解除分页锁。
    isLoadingMore = false;
    isRefreshing = hasContent;
    if (!hasContent) {
      viewState = TeamFeedViewState.loading;
    }
    publicError = null;
    refreshWarning = null;
    notifyListeners();
    try {
      final result = await _service.list(
        category: currentCategory,
        status: currentStatus,
        keyword: currentKeyword,
        sort: currentSort,
        availableOnly: currentAvailableOnly,
        page: 1,
        cancelToken: cancelToken,
      );
      if (requestVersion != _publicRequestVersion) return;
      publicItems = result.items;
      publicPage = result.page;
      publicTotal = result.total;
      publicHasMore = result.hasMore;
      viewState = result.items.isEmpty
          ? TeamFeedViewState.empty
          : TeamFeedViewState.content;
    } on DioException catch (error) {
      if (CancelToken.isCancel(error) ||
          requestVersion != _publicRequestVersion) {
        return;
      }
      publicStatusCode = error.response?.statusCode;
      final state = _mapTeamError(error);
      final message = _feedErrorMessage(state);
      if (hasContent) {
        viewState = TeamFeedViewState.content;
        refreshWarning = message;
      } else {
        viewState = state;
        publicError = message;
      }
    } catch (_) {
      if (requestVersion != _publicRequestVersion) return;
      if (hasContent) {
        viewState = TeamFeedViewState.content;
        refreshWarning = '刷新失败，当前显示上次结果';
      } else {
        viewState = TeamFeedViewState.serverError;
        publicError = _feedErrorMessage(viewState);
      }
    } finally {
      if (requestVersion == _publicRequestVersion) {
        isLoadingPublic = false;
        isRefreshing = false;
        notifyListeners();
      }
    }
  }

  Future<void> loadMorePublic() async {
    if (isLoadingPublic || isLoadingMore || !publicHasMore) return;
    final requestVersion = _publicRequestVersion;
    isLoadingMore = true;
    notifyListeners();
    try {
      final result = await _service.list(
        category: currentCategory,
        status: currentStatus,
        keyword: currentKeyword,
        sort: currentSort,
        availableOnly: currentAvailableOnly,
        page: publicPage + 1,
      );
      if (requestVersion != _publicRequestVersion) return;
      publicItems = [...publicItems, ...result.items];
      publicPage = result.page;
      publicTotal = result.total;
      publicHasMore = result.hasMore;
    } catch (_) {
      if (requestVersion == _publicRequestVersion) {
        refreshWarning = '加载更多失败，点击重试';
      }
    } finally {
      if (requestVersion == _publicRequestVersion) {
        isLoadingMore = false;
        notifyListeners();
      }
    }
  }

  Future<TeamRecruitment?> loadDetail(int recruitmentId) async {
    final sessionVersion = _sessionVersion;
    try {
      final item = await _service.detail(recruitmentId);
      if (sessionVersion != _sessionVersion) return null;
      _upsertRecruitment(item);
      notifyListeners();
      return item;
    } catch (_) {
      return null;
    }
  }

  Future<TeamRecruitment?> create({
    required String category,
    required String title,
    required String description,
    required int neededCount,
    required List<String> roles,
    DateTime? deadline,
    List<XFile> images = const [],
  }) async {
    if (isCreating) return null;
    final sessionVersion = _sessionVersion;
    isCreating = true;
    notifyListeners();
    try {
      final fileIds = await _uploadImages(images);
      if (sessionVersion != _sessionVersion) return null;
      final created = await _service.create(
        category: category,
        title: title,
        description: description,
        neededCount: neededCount,
        roles: roles,
        deadline: deadline,
        imageFileIds: fileIds,
      );
      if (sessionVersion != _sessionVersion) return null;
      myCreated = [created, ...myCreated];
      _upsertRecruitment(created);
      return created;
    } catch (_) {
      return null;
    } finally {
      if (sessionVersion == _sessionVersion) {
        isCreating = false;
        notifyListeners();
      }
    }
  }

  Future<TeamOperationResult<TeamRecruitment>> updateRecruitment({
    required int recruitmentId,
    required String category,
    required String title,
    required String description,
    required int neededCount,
    required List<String> roles,
    DateTime? deadline,
    List<int>? imageFileIds,
    List<XFile> images = const [],
  }) async {
    if (updatingIds.contains(recruitmentId)) {
      return const TeamOperationResult.failure(
          '正在保存，请勿重复提交', TeamErrorType.validation);
    }
    final sessionVersion = _sessionVersion;
    updatingIds.add(recruitmentId);
    notifyListeners();
    try {
      final uploadedIds = await _uploadImages(images);
      if (sessionVersion != _sessionVersion) {
        return const TeamOperationResult.failure(
            '登录状态已变化，请重试', TeamErrorType.unauthorized);
      }
      final finalImageIds = imageFileIds == null && uploadedIds.isEmpty
          ? null
          : [...?imageFileIds, ...uploadedIds];
      final updated = await _service.update(
        recruitmentId: recruitmentId,
        category: category,
        title: title,
        description: description,
        neededCount: neededCount,
        roles: roles,
        deadline: deadline,
        imageFileIds: finalImageIds,
      );
      if (sessionVersion != _sessionVersion) {
        return const TeamOperationResult.failure(
            '登录状态已变化，请重试', TeamErrorType.unauthorized);
      }
      _upsertRecruitment(updated);
      notifyListeners();
      return TeamOperationResult.success(updated);
    } catch (error) {
      if (sessionVersion != _sessionVersion) {
        return const TeamOperationResult.failure(
            '登录状态已变化，请重试', TeamErrorType.unauthorized);
      }
      return TeamOperationResult.failure(_error(error), _errorType(error));
    } finally {
      if (sessionVersion == _sessionVersion) {
        updatingIds.remove(recruitmentId);
        notifyListeners();
      }
    }
  }

  Future<void> loadMine() async {
    final requestVersion = ++_mineRequestVersion;
    final sessionVersion = _sessionVersion;
    _mineCancelToken?.cancel('已由最新请求替代');
    final cancelToken = _mineCancelToken = CancelToken();
    isLoadingMine = true;
    mineError = null;
    notifyListeners();
    try {
      final created = await _service.mine(cancelToken: cancelToken);
      if (requestVersion != _mineRequestVersion ||
          sessionVersion != _sessionVersion) {
        return;
      }
      final applications =
          await _service.myApplications(cancelToken: cancelToken);
      if (requestVersion != _mineRequestVersion ||
          sessionVersion != _sessionVersion) {
        return;
      }
      myCreated = created;
      myApplications = applications;
    } catch (error) {
      if (requestVersion != _mineRequestVersion ||
          sessionVersion != _sessionVersion) {
        return;
      }
      mineError = _error(error);
    } finally {
      if (requestVersion == _mineRequestVersion &&
          sessionVersion == _sessionVersion) {
        isLoadingMine = false;
        notifyListeners();
      }
    }
  }

  List<WaterTeamApplication> applicationsFor(int recruitmentId) =>
      List.unmodifiable(_applications[recruitmentId] ?? const []);

  Future<void> loadApplications(int recruitmentId) async {
    if (loadingApplicationIds.contains(recruitmentId)) return;
    final sessionVersion = _sessionVersion;
    loadingApplicationIds.add(recruitmentId);
    applicationErrors.remove(recruitmentId);
    notifyListeners();
    try {
      final applications = await _service.applications(recruitmentId);
      if (sessionVersion != _sessionVersion) return;
      _applications[recruitmentId] = applications;
    } catch (error) {
      if (sessionVersion != _sessionVersion) return;
      applicationErrors[recruitmentId] = _error(error);
    } finally {
      if (sessionVersion == _sessionVersion) {
        loadingApplicationIds.remove(recruitmentId);
        notifyListeners();
      }
    }
  }

  Future<String?> apply(
      {required int recruitmentId,
      required String message,
      String availability = ''}) async {
    if (applyingIds.contains(recruitmentId)) return '申请正在提交，请勿重复操作';
    final sessionVersion = _sessionVersion;
    final actionKey = 'team-apply:$recruitmentId:$message:$availability';
    applyingIds.add(recruitmentId);
    notifyListeners();
    try {
      await _service.apply(
          recruitmentId: recruitmentId,
          message: message,
          availability: availability,
          idempotencyKey: _idempotencyKeyFor(actionKey));
      if (sessionVersion != _sessionVersion) return '登录状态已变化，请重试';
      _idempotencyKeys.remove(actionKey);
      return null;
    } catch (error) {
      if (sessionVersion != _sessionVersion) return '登录状态已变化，请重试';
      return _error(error);
    } finally {
      if (sessionVersion == _sessionVersion) {
        applyingIds.remove(recruitmentId);
        notifyListeners();
      }
    }
  }

  String _idempotencyKeyFor(String actionKey) => _idempotencyKeys.putIfAbsent(
        actionKey,
        () => newIdempotencyKey('team'),
      );

  Future<String?> cancel(int applicationId) async {
    if (reviewingApplicationIds.contains(applicationId)) return '正在处理，请勿重复操作';
    final sessionVersion = _sessionVersion;
    final actionKey = 'team-cancel:$applicationId';
    reviewingApplicationIds.add(applicationId);
    notifyListeners();
    try {
      await _service.cancel(
        applicationId,
        idempotencyKey: _idempotencyKeyFor(actionKey),
      );
      if (sessionVersion != _sessionVersion) return '登录状态已变化，请重试';
      _idempotencyKeys.remove(actionKey);
      return null;
    } catch (error) {
      if (sessionVersion != _sessionVersion) return '登录状态已变化，请重试';
      return _error(error);
    } finally {
      if (sessionVersion == _sessionVersion) {
        reviewingApplicationIds.remove(applicationId);
        notifyListeners();
      }
    }
  }

  Future<String?> leave(int applicationId) =>
      _changeMembership(applicationId, remove: false);

  Future<String?> remove(int applicationId) =>
      _changeMembership(applicationId, remove: true);

  Future<String?> _changeMembership(int applicationId,
      {required bool remove}) async {
    if (reviewingApplicationIds.contains(applicationId)) return '正在处理，请勿重复操作';
    final sessionVersion = _sessionVersion;
    final actionKey =
        'team-membership:${remove ? 'remove' : 'leave'}:$applicationId';
    reviewingApplicationIds.add(applicationId);
    notifyListeners();
    try {
      if (remove) {
        await _service.remove(
          applicationId,
          idempotencyKey: _idempotencyKeyFor(actionKey),
        );
      } else {
        await _service.leave(
          applicationId,
          idempotencyKey: _idempotencyKeyFor(actionKey),
        );
      }
      if (sessionVersion != _sessionVersion) return '登录状态已变化，请重试';
      _idempotencyKeys.remove(actionKey);
      return null;
    } catch (error) {
      if (sessionVersion != _sessionVersion) return '登录状态已变化，请重试';
      return _error(error);
    } finally {
      if (sessionVersion == _sessionVersion) {
        reviewingApplicationIds.remove(applicationId);
        notifyListeners();
      }
    }
  }

  Future<String?> review(int applicationId,
      {required bool accepted, String reply = ''}) async {
    if (reviewingApplicationIds.contains(applicationId)) return '正在处理，请勿重复操作';
    final sessionVersion = _sessionVersion;
    final actionKey = 'team-review:$applicationId:$accepted:$reply';
    reviewingApplicationIds.add(applicationId);
    notifyListeners();
    try {
      if (accepted) {
        await _service.accept(
          applicationId,
          reply: reply,
          idempotencyKey: _idempotencyKeyFor(actionKey),
        );
      } else {
        await _service.reject(
          applicationId,
          reply: reply,
          idempotencyKey: _idempotencyKeyFor(actionKey),
        );
      }
      if (sessionVersion != _sessionVersion) return '登录状态已变化，请重试';
      _idempotencyKeys.remove(actionKey);
      return null;
    } catch (error) {
      if (sessionVersion != _sessionVersion) return '登录状态已变化，请重试';
      return _error(error);
    } finally {
      if (sessionVersion == _sessionVersion) {
        reviewingApplicationIds.remove(applicationId);
        notifyListeners();
      }
    }
  }

  Future<String?> updateStatus(int recruitmentId, String status) async {
    if (closingIds.contains(recruitmentId)) return '正在更新状态，请勿重复操作';
    final sessionVersion = _sessionVersion;
    final actionKey = 'team-status:$recruitmentId:$status';
    closingIds.add(recruitmentId);
    notifyListeners();
    try {
      await _service.updateStatus(
        recruitmentId,
        status,
        idempotencyKey: _idempotencyKeyFor(actionKey),
      );
      if (sessionVersion != _sessionVersion) return '登录状态已变化，请重试';
      _idempotencyKeys.remove(actionKey);
      return null;
    } catch (error) {
      if (sessionVersion != _sessionVersion) return '登录状态已变化，请重试';
      return _error(error);
    } finally {
      if (sessionVersion == _sessionVersion) {
        closingIds.remove(recruitmentId);
        notifyListeners();
      }
    }
  }

  Future<String?> deleteRecruitment(int recruitmentId) async {
    if (deletingIds.contains(recruitmentId)) return '正在删除，请勿重复操作';
    final sessionVersion = _sessionVersion;
    final actionKey = 'team-delete:$recruitmentId';
    deletingIds.add(recruitmentId);
    notifyListeners();
    try {
      await _service.delete(
        recruitmentId,
        idempotencyKey: _idempotencyKeyFor(actionKey),
      );
      if (sessionVersion != _sessionVersion) return '登录状态已变化，请重试';
      _idempotencyKeys.remove(actionKey);

      final removedFromPublic =
          publicItems.any((item) => item.id == recruitmentId);
      publicItems = publicItems
          .where((item) => item.id != recruitmentId)
          .toList(growable: false);
      myCreated = myCreated
          .where((item) => item.id != recruitmentId)
          .toList(growable: false);
      myApplications = myApplications
          .where((item) => item.recruitmentId != recruitmentId)
          .toList(growable: false);
      _applications.remove(recruitmentId);
      if (removedFromPublic && publicTotal > 0) publicTotal--;
      return null;
    } catch (error) {
      if (sessionVersion != _sessionVersion) return '登录状态已变化，请重试';
      return _error(error);
    } finally {
      if (sessionVersion == _sessionVersion) {
        deletingIds.remove(recruitmentId);
        notifyListeners();
      }
    }
  }

  String _error(Object error) {
    if (error is DioException && error.response?.data is Map) {
      return error.response!.data['error']?.toString() ?? '请求失败';
    }
    return '请求失败，请稍后重试';
  }

  TeamErrorType _errorType(Object error) {
    if (error is DioException) {
      final code = error.response?.statusCode;
      if (code == 401) return TeamErrorType.unauthorized;
      if (code == 400 || code == 422) return TeamErrorType.validation;
      if (code == 404 || code == 405) return TeamErrorType.unavailable;
      if (error.type == DioExceptionType.connectionError ||
          error.type == DioExceptionType.connectionTimeout ||
          error.type == DioExceptionType.receiveTimeout ||
          error.type == DioExceptionType.sendTimeout) {
        return TeamErrorType.network;
      }
    }
    return TeamErrorType.server;
  }

  TeamFeedViewState _mapTeamError(DioException error) {
    final code = error.response?.statusCode;
    if (code == 404 || code == 405) {
      return TeamFeedViewState.unavailable;
    }
    if (code != null && code >= 500) {
      return TeamFeedViewState.serverError;
    }
    if (error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.receiveTimeout ||
        error.type == DioExceptionType.connectionError ||
        error.type == DioExceptionType.sendTimeout) {
      return TeamFeedViewState.networkError;
    }
    return TeamFeedViewState.serverError;
  }

  String _feedErrorMessage(TeamFeedViewState state) {
    return switch (state) {
      TeamFeedViewState.unavailable => '组队服务暂未上线',
      TeamFeedViewState.networkError => '网络连接失败',
      TeamFeedViewState.serverError => '组队服务暂时不可用',
      _ => '请求失败，请稍后重试',
    };
  }

  Future<List<int>> _uploadImages(List<XFile> images) async {
    final fileIds = <int>[];
    for (final source in images) {
      final prepared = await _publicImageCompressor.prepare(source);
      try {
        final bytes = await prepared.file.readAsBytes();
        final response = await _dio.post('/upload',
            data: FormData.fromMap({
              'file': MultipartFile.fromBytes(
                bytes,
                filename: prepared.file.name,
              ),
            }));
        final id =
            (response.data is Map ? response.data['file_id'] : null) as num?;
        if (id == null) throw StateError('图片上传失败');
        fileIds.add(id.toInt());
      } finally {
        await prepared.dispose();
      }
    }
    return fileIds;
  }

  void _upsertRecruitment(TeamRecruitment updated) {
    publicItems = publicItems
        .map((item) => item.id == updated.id ? updated : item)
        .toList(growable: false);
    final mineIndex = myCreated.indexWhere((item) => item.id == updated.id);
    if (mineIndex >= 0) {
      myCreated = myCreated
          .map((item) => item.id == updated.id ? updated : item)
          .toList(growable: false);
    }
  }

  @override
  void dispose() {
    _publicCancelToken?.cancel('Provider 已销毁');
    _mineCancelToken?.cancel('Provider 已销毁');
    super.dispose();
  }
}
