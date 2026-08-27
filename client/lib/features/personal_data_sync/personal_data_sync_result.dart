import 'personal_data_source.dart';
import 'personal_data_sync_models.dart';

/// 每个数据集的最终处理状态。使用旧缓存表示本次没有刷新成功，但已有数据未被删除。
enum PersonalSyncItemStatus {
  success,
  failed,
  skipped,
  usingOldCache,
  permissionDenied,
}

enum PersonalSyncFailureReason {
  eduSessionExpired,
  authorizationRequired,
  credentialUnavailable,
  networkUnavailable,
  refreshIncomplete,
  localStorageFailed,
  unknown,
}

class PersonalSyncItemResult {
  const PersonalSyncItemResult({
    required this.dataset,
    required this.status,
    required this.source,
    this.updatedAt,
    this.isPartial = false,
    this.message,
    this.failureReason,
  });

  final PersonalSyncDataset dataset;
  final PersonalSyncItemStatus status;
  final PersonalDataSource source;
  final DateTime? updatedAt;
  final bool isPartial;
  final String? message;
  final PersonalSyncFailureReason? failureReason;

  bool get isSuccessful =>
      status == PersonalSyncItemStatus.success ||
      status == PersonalSyncItemStatus.usingOldCache;
}

/// 一次同步的不可变汇总。单项失败不会覆盖其他数据集的结果。
class PersonalSyncResult {
  PersonalSyncResult({
    required Map<PersonalSyncDataset, PersonalSyncItemResult> items,
    required this.trigger,
    required this.startedAt,
    required this.completedAt,
  }) : items = Map<PersonalSyncDataset, PersonalSyncItemResult>.unmodifiable(
          items,
        );

  final Map<PersonalSyncDataset, PersonalSyncItemResult> items;
  final PersonalSyncTrigger trigger;
  final DateTime startedAt;
  final DateTime completedAt;

  bool get hasFailures => items.values.any(
        (item) => item.status == PersonalSyncItemStatus.failed,
      );

  bool get hasPartialResults => items.values.any(
        (item) =>
            item.isPartial ||
            item.status == PersonalSyncItemStatus.usingOldCache,
      );

  bool get isFullySuccessful => items.values.every(
        (item) =>
            item.status == PersonalSyncItemStatus.success && !item.isPartial,
      );
}
