import '../../providers/edu_provider.dart';
import '../../utils/edu_semester_utils.dart';
import '../campus_data/erke/erke_repository.dart';
import 'erke_snapshot_upload.dart';
import 'personal_data_source.dart';
import 'personal_data_sync_models.dart';
import 'personal_data_sync_progress.dart';
import 'personal_data_sync_result.dart';

/// 教务同步实现的最小接口，使协调器不依赖具体页面或网络客户端。
abstract interface class PersonalAcademicSyncGateway {
  Future<PersonalSyncItemResult> syncSchedule();
  Future<PersonalSyncItemResult> syncGrades();
  Future<PersonalSyncItemResult> syncAcademicSituation();
  Future<PersonalSyncItemResult> syncCreditRequirements();
}

/// 二课同步只能在手机完成。调用方负责以安全交互方式获取本次临时凭据。
abstract interface class PersonalErkeSyncGateway {
  Future<PersonalSyncItemResult> syncErke();
}

/// 本次二课更新所需的临时凭据；不得序列化、缓存或上传到服务器。
class PersonalErkeCredentials {
  const PersonalErkeCredentials({
    required this.studentId,
    required this.casPassword,
    required this.erkePassword,
  });

  final String studentId;
  final String casPassword;
  final String erkePassword;
}

/// 复用既有 [EduProvider] 的本机教务更新能力，并沿用其本地加密缓存写入逻辑。
class EduProviderPersonalAcademicSyncGateway
    implements PersonalAcademicSyncGateway {
  EduProviderPersonalAcademicSyncGateway(this._provider,
      {DateTime Function()? now})
      : _now = now ?? DateTime.now;

  final EduProvider _provider;
  final DateTime Function() _now;

  @override
  Future<PersonalSyncItemResult> syncSchedule() async {
    final term = EduSemester.current();
    final result = await _provider.getCourses(term.year, term.semester);
    if (result?.success == true) {
      return PersonalSyncItemResult(
        dataset: PersonalSyncDataset.schedule,
        status: PersonalSyncItemStatus.success,
        source: PersonalDataSource.remoteEduFetch,
        updatedAt: _now(),
      );
    }
    return _failed(
      PersonalSyncDataset.schedule,
      result?.errorMessage ?? '更新课表失败',
      result?.errorCode,
    );
  }

  @override
  Future<PersonalSyncItemResult> syncGrades() async {
    final result = await _provider.syncAllGrades();
    if (!result.success) {
      return _failed(
        PersonalSyncDataset.grades,
        result.errorMessage ?? '更新成绩失败',
        result.errorCode,
      );
    }
    final totalTerms =
        EduSemester.buildSemesterList(_provider.enrollmentYear).length;
    final syncedTerms = result.data ?? 0;
    final isPartial = syncedTerms < totalTerms;
    return PersonalSyncItemResult(
      dataset: PersonalSyncDataset.grades,
      status: PersonalSyncItemStatus.success,
      source: PersonalDataSource.remoteEduFetch,
      updatedAt: _now(),
      isPartial: isPartial,
      message: isPartial ? '仅同步了 $syncedTerms/$totalTerms 个学期，已保留已有缓存' : null,
      failureReason:
          isPartial ? PersonalSyncFailureReason.refreshIncomplete : null,
    );
  }

  @override
  Future<PersonalSyncItemResult> syncAcademicSituation() async {
    final result = await _provider.fetchAcademicSituation();
    if (result.success) {
      return PersonalSyncItemResult(
        dataset: PersonalSyncDataset.academicSituation,
        status: PersonalSyncItemStatus.success,
        source: PersonalDataSource.remoteEduFetch,
        updatedAt: _now(),
      );
    }
    return _failed(
      PersonalSyncDataset.academicSituation,
      result.errorMessage ?? '更新学业情况失败',
      result.errorCode,
    );
  }

  @override
  Future<PersonalSyncItemResult> syncCreditRequirements() async {
    final result = await _provider.fetchCreditRequirements();
    if (result.success) {
      return PersonalSyncItemResult(
        dataset: PersonalSyncDataset.creditRequirements,
        status: PersonalSyncItemStatus.success,
        source: PersonalDataSource.remoteEduFetch,
        updatedAt: _now(),
      );
    }
    return _failed(
      PersonalSyncDataset.creditRequirements,
      result.errorMessage ?? '更新学分要求失败',
      result.errorCode,
    );
  }

  PersonalSyncItemResult _failed(
    PersonalSyncDataset dataset,
    String message, [
    String? errorCode,
  ]) =>
      PersonalSyncItemResult(
        dataset: dataset,
        status: PersonalSyncItemStatus.failed,
        source: PersonalDataSource.none,
        message: message,
        failureReason: _failureReason(errorCode),
      );

  PersonalSyncFailureReason _failureReason(String? code) {
    switch (code?.trim().toLowerCase()) {
      case 'edu_authorization_revoked':
      case 'edu_session_logged_out':
      case 'edu_session_expired':
        return PersonalSyncFailureReason.eduSessionExpired;
      case 'credential_unavailable':
      case 'edu_credential_unavailable':
        return PersonalSyncFailureReason.credentialUnavailable;
      case 'network_unavailable':
        return PersonalSyncFailureReason.networkUnavailable;
      case 'refresh_incomplete':
        return PersonalSyncFailureReason.refreshIncomplete;
      case 'local_storage_failed':
        return PersonalSyncFailureReason.localStorageFailed;
      case 'authorization_required':
        return PersonalSyncFailureReason.authorizationRequired;
      default:
        return PersonalSyncFailureReason.unknown;
    }
  }
}

/// 二课适配器复用既有 WebVPN 和解析器，只持有调用期间的临时凭据。
class ErkeRepositoryPersonalSyncGateway implements PersonalErkeSyncGateway {
  ErkeRepositoryPersonalSyncGateway({
    required ErkeRepository repository,
    required Future<PersonalErkeCredentials?> Function() requestCredentials,
    ErkeSnapshotUploadGateway? snapshotUploader,
    ErkeSnapshotUploadPolicyStore? uploadPolicyStore,
    Future<ErkeSnapshotUploadPolicy?> Function()? requestUploadPolicy,
    bool automationUploadAllowed = false,
    DateTime Function()? now,
  })  : _repository = repository,
        _requestCredentials = requestCredentials,
        _snapshotUploader = snapshotUploader,
        _uploadPolicyStore = uploadPolicyStore,
        _requestUploadPolicy = requestUploadPolicy,
        _automationUploadAllowed = automationUploadAllowed,
        _now = now ?? DateTime.now;

  final ErkeRepository _repository;
  final Future<PersonalErkeCredentials?> Function() _requestCredentials;
  final ErkeSnapshotUploadGateway? _snapshotUploader;
  final ErkeSnapshotUploadPolicyStore? _uploadPolicyStore;
  final Future<ErkeSnapshotUploadPolicy?> Function()? _requestUploadPolicy;
  final bool _automationUploadAllowed;
  final DateTime Function() _now;

  @override
  Future<PersonalSyncItemResult> syncErke(
      {bool automationUpload = false}) async {
    final credentials = await _requestCredentials();
    if (credentials == null) {
      return const PersonalSyncItemResult(
        dataset: PersonalSyncDataset.erke,
        status: PersonalSyncItemStatus.permissionDenied,
        source: PersonalDataSource.none,
        message: '未授权更新二课数据',
      );
    }
    final updated = await _repository.loginAndFetch(
      credentials.studentId,
      credentials.casPassword,
      credentials.erkePassword,
    );
    if (updated) {
      final uploadMessage =
          await _uploadAuthorizedSnapshot(automation: automationUpload);
      return PersonalSyncItemResult(
        dataset: PersonalSyncDataset.erke,
        status: PersonalSyncItemStatus.success,
        source: PersonalDataSource.deviceEncryptedCache,
        updatedAt: _now(),
        message: uploadMessage,
      );
    }
    if (_repository.hasCachedData) {
      return PersonalSyncItemResult(
        dataset: PersonalSyncDataset.erke,
        status: PersonalSyncItemStatus.usingOldCache,
        source: PersonalDataSource.deviceEncryptedCache,
        message: _repository.fetchError ?? '二课更新失败，继续使用已有缓存',
        failureReason: _erkeFailureReason(_repository.failureCategory),
      );
    }
    return PersonalSyncItemResult(
      dataset: PersonalSyncDataset.erke,
      status: PersonalSyncItemStatus.failed,
      source: PersonalDataSource.none,
      message: _repository.fetchError ?? '更新二课数据失败',
      failureReason: _erkeFailureReason(_repository.failureCategory),
    );
  }

  PersonalSyncFailureReason _erkeFailureReason(
    ErkeFetchFailureCategory category,
  ) {
    switch (category) {
      case ErkeFetchFailureCategory.credentialInvalid:
        return PersonalSyncFailureReason.credentialUnavailable;
      case ErkeFetchFailureCategory.networkUnavailable:
        return PersonalSyncFailureReason.networkUnavailable;
      case ErkeFetchFailureCategory.unknown:
        return PersonalSyncFailureReason.unknown;
    }
  }

  /// 上传只发生在本地更新成功之后；上传错误不能影响本地缓存和本次二课更新结果。
  ///
  /// [automation] 表示本次刷新来自校园 Agent 的设备任务，且服务端已确认用户
  /// 授权 AI 使用二课快照；此时“每次询问”策略按单次上传处理，不弹出询问、
  /// 也不改写用户保存的策略，“从不上传”仍然生效。
  Future<String?> _uploadAuthorizedSnapshot({bool automation = false}) async {
    final uploader = _snapshotUploader;
    final policyStore = _uploadPolicyStore;
    if (uploader == null || policyStore == null) return null;

    var policy = await policyStore.read();
    final automationOverride =
        automation && _automationUploadAllowed && _requestUploadPolicy == null;
    if (policy == ErkeSnapshotUploadPolicy.askEveryUpdate &&
        !automationOverride) {
      policy = await _requestUploadPolicy?.call() ?? policy;
    }
    switch (policy) {
      case ErkeSnapshotUploadPolicy.askEveryUpdate:
        if (automationOverride) break;
        return '二课摘要未上传，下次更新时会再次询问';
      case ErkeSnapshotUploadPolicy.neverUpload:
        await policyStore.write(policy);
        return '已按你的设置保留二课摘要在本机';
      case ErkeSnapshotUploadPolicy.autoUploadSummary:
        await policyStore.write(policy);
        break;
      case ErkeSnapshotUploadPolicy.uploadThisTime:
        break;
    }

    final snapshot = await _repository.readSnapshotForAuthorizedUpload();
    if (snapshot == null) return '二课已更新，但未找到可上传的本地快照';
    try {
      await uploader.upload(snapshot);
      return '二课摘要已按授权上传，可供校园 Agent 使用';
    } on ErkeSnapshotUploadException {
      return '二课已更新，但摘要上传失败';
    }
  }
}

/// 按固定阶段协调教务与二课同步。任一数据集失败不会取消或回滚已完成的数据集。
class PersonalDataSyncCoordinator {
  PersonalDataSyncCoordinator({
    required PersonalAcademicSyncGateway academicGateway,
    PersonalErkeSyncGateway? erkeGateway,
    DateTime Function()? now,
  })  : _academicGateway = academicGateway,
        _erkeGateway = erkeGateway,
        _now = now ?? DateTime.now;

  final PersonalAcademicSyncGateway _academicGateway;
  final PersonalErkeSyncGateway? _erkeGateway;
  final DateTime Function() _now;

  Future<PersonalSyncResult> sync({
    required Set<PersonalSyncDataset> datasets,
    required PersonalSyncTrigger trigger,
    PersonalSyncProgressListener? onProgress,
  }) async {
    final startedAt = _now();
    final items = <PersonalSyncDataset, PersonalSyncItemResult>{};

    for (final dataset in const <PersonalSyncDataset>[
      PersonalSyncDataset.schedule,
      PersonalSyncDataset.grades,
      PersonalSyncDataset.academicSituation,
      PersonalSyncDataset.creditRequirements,
    ]) {
      if (!datasets.contains(dataset)) continue;
      items[dataset] = await _runAcademic(dataset, onProgress);
    }

    if (datasets.contains(PersonalSyncDataset.erke)) {
      items[PersonalSyncDataset.erke] = await _runErke(onProgress);
    }

    return PersonalSyncResult(
      items: items,
      trigger: trigger,
      startedAt: startedAt,
      completedAt: _now(),
    );
  }

  Future<PersonalSyncItemResult> _runAcademic(
    PersonalSyncDataset dataset,
    PersonalSyncProgressListener? onProgress,
  ) async {
    onProgress?.call(PersonalSyncProgress(
      dataset: dataset,
      phase: PersonalSyncPhase.serverEducation,
      isRunning: true,
    ));
    try {
      final result = switch (dataset) {
        PersonalSyncDataset.schedule => _academicGateway.syncSchedule(),
        PersonalSyncDataset.grades => _academicGateway.syncGrades(),
        PersonalSyncDataset.academicSituation =>
          _academicGateway.syncAcademicSituation(),
        PersonalSyncDataset.creditRequirements =>
          _academicGateway.syncCreditRequirements(),
        PersonalSyncDataset.erke => throw StateError('二课不属于教务阶段'),
      };
      final item = await result;
      onProgress?.call(PersonalSyncProgress(
        dataset: dataset,
        phase: PersonalSyncPhase.serverEducation,
        isRunning: false,
        message: item.message,
      ));
      return item;
    } catch (_) {
      const message = '更新失败，已有缓存未被删除';
      onProgress?.call(PersonalSyncProgress(
        dataset: dataset,
        phase: PersonalSyncPhase.serverEducation,
        isRunning: false,
        message: message,
      ));
      return PersonalSyncItemResult(
        dataset: dataset,
        status: PersonalSyncItemStatus.failed,
        source: PersonalDataSource.none,
        message: message,
        failureReason: PersonalSyncFailureReason.unknown,
      );
    }
  }

  Future<PersonalSyncItemResult> _runErke(
    PersonalSyncProgressListener? onProgress,
  ) async {
    const dataset = PersonalSyncDataset.erke;
    final erkeGateway = _erkeGateway;
    if (erkeGateway == null) {
      return const PersonalSyncItemResult(
        dataset: dataset,
        status: PersonalSyncItemStatus.skipped,
        source: PersonalDataSource.none,
        message: '当前入口不能更新二课数据',
      );
    }
    onProgress?.call(const PersonalSyncProgress(
      dataset: dataset,
      phase: PersonalSyncPhase.deviceErke,
      isRunning: true,
    ));
    try {
      final item = await erkeGateway.syncErke();
      onProgress?.call(PersonalSyncProgress(
        dataset: dataset,
        phase: PersonalSyncPhase.deviceErke,
        isRunning: false,
        message: item.message,
      ));
      return item;
    } catch (_) {
      const message = '更新二课数据失败，已有缓存未被删除';
      onProgress?.call(const PersonalSyncProgress(
        dataset: dataset,
        phase: PersonalSyncPhase.deviceErke,
        isRunning: false,
        message: message,
      ));
      return const PersonalSyncItemResult(
        dataset: dataset,
        status: PersonalSyncItemStatus.failed,
        source: PersonalDataSource.none,
        message: message,
      );
    }
  }
}
