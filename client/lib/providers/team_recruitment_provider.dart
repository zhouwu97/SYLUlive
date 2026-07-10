import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';

import '../models/team_recruitment.dart';
import '../models/water_team.dart';
import '../services/team_recruitment_service.dart';

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

/// 组队大厅独立状态；不会刷新或修改普通水帖的信息流缓存。
class TeamRecruitmentProvider extends ChangeNotifier {
  final Dio _dio;
  late final TeamRecruitmentService _service = TeamRecruitmentService(_dio);

  TeamRecruitmentProvider(this._dio);

  List<TeamRecruitment> publicItems = const [];
  List<TeamRecruitment> myCreated = const [];
  List<WaterTeamApplication> myApplications = const [];
  final Map<int, List<WaterTeamApplication>> _applications = {};
  TeamFeedViewState viewState = TeamFeedViewState.initial;
  bool isLoadingPublic = false;
  bool isLoadingMine = false;
  bool isCreating = false;
  String? publicError;
  int? publicStatusCode;
  String? mineError;
  final Set<int> applyingIds = {};
  final Set<int> closingIds = {};
  final Set<int> reviewingApplicationIds = {};

  Future<void> loadPublic(
      {String? category, String? status, bool force = false}) async {
    isLoadingPublic = true;
    if (publicItems.isEmpty) {
      viewState = TeamFeedViewState.loading;
    }
    publicError = null;
    publicStatusCode = null;
    notifyListeners();
    try {
      final items = await _service.list(category: category, status: status);
      publicItems = items;
      viewState =
          items.isEmpty ? TeamFeedViewState.empty : TeamFeedViewState.content;
    } on DioException catch (error) {
      publicStatusCode = error.response?.statusCode;
      viewState = _mapTeamError(error);
      publicError = _feedErrorMessage(viewState);
    } catch (_) {
      viewState = TeamFeedViewState.serverError;
      publicError = _feedErrorMessage(viewState);
    } finally {
      isLoadingPublic = false;
      notifyListeners();
    }
  }

  Future<TeamRecruitment?> loadDetail(int recruitmentId) async {
    try {
      return await _service.detail(recruitmentId);
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
    isCreating = true;
    notifyListeners();
    try {
      final fileIds = <int>[];
      for (final image in images) {
        final bytes = await image.readAsBytes();
        final response = await _dio.post('/upload',
            data: FormData.fromMap({
              'file': MultipartFile.fromBytes(bytes, filename: image.name),
            }));
        final id =
            (response.data is Map ? response.data['file_id'] : null) as num?;
        if (id == null) throw StateError('图片上传失败');
        fileIds.add(id.toInt());
      }
      final created = await _service.create(
        category: category,
        title: title,
        description: description,
        neededCount: neededCount,
        roles: roles,
        deadline: deadline,
        imageFileIds: fileIds,
      );
      myCreated = [created, ...myCreated];
      return created;
    } catch (_) {
      return null;
    } finally {
      isCreating = false;
      notifyListeners();
    }
  }

  Future<void> loadMine() async {
    isLoadingMine = true;
    mineError = null;
    notifyListeners();
    try {
      myCreated = await _service.mine();
      myApplications = await _service.myApplications();
    } catch (error) {
      mineError = _error(error);
    } finally {
      isLoadingMine = false;
      notifyListeners();
    }
  }

  List<WaterTeamApplication> applicationsFor(int recruitmentId) =>
      List.unmodifiable(_applications[recruitmentId] ?? const []);

  Future<void> loadApplications(int recruitmentId) async {
    _applications[recruitmentId] = await _service.applications(recruitmentId);
    notifyListeners();
  }

  Future<String?> apply(
      {required int recruitmentId,
      required String message,
      String availability = ''}) async {
    applyingIds.add(recruitmentId);
    notifyListeners();
    try {
      await _service.apply(
          recruitmentId: recruitmentId,
          message: message,
          availability: availability);
      return null;
    } catch (error) {
      return _error(error);
    } finally {
      applyingIds.remove(recruitmentId);
      notifyListeners();
    }
  }

  Future<String?> cancel(int applicationId) async {
    reviewingApplicationIds.add(applicationId);
    notifyListeners();
    try {
      await _service.cancel(applicationId);
      return null;
    } catch (error) {
      return _error(error);
    } finally {
      reviewingApplicationIds.remove(applicationId);
      notifyListeners();
    }
  }

  Future<String?> review(int applicationId,
      {required bool accepted, String reply = ''}) async {
    reviewingApplicationIds.add(applicationId);
    notifyListeners();
    try {
      if (accepted) {
        await _service.accept(applicationId, reply: reply);
      } else {
        await _service.reject(applicationId, reply: reply);
      }
      return null;
    } catch (error) {
      return _error(error);
    } finally {
      reviewingApplicationIds.remove(applicationId);
      notifyListeners();
    }
  }

  Future<String?> updateStatus(int recruitmentId, String status) async {
    closingIds.add(recruitmentId);
    notifyListeners();
    try {
      await _service.updateStatus(recruitmentId, status);
      return null;
    } catch (error) {
      return _error(error);
    } finally {
      closingIds.remove(recruitmentId);
      notifyListeners();
    }
  }

  String _error(Object error) {
    if (error is DioException && error.response?.data is Map) {
      return error.response!.data['error']?.toString() ?? '请求失败';
    }
    return '请求失败，请稍后重试';
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
}
