library;

/// The overall state of the evaluation batch automation flow.
enum EvaluationAutomationState {
  idle,
  probing,
  filling,
  validating,
  saving,
  waitingForSave,
  switchingNext,
  waitingForForm,
  paused,
  completed,
  stopped,
  failed,
}

/// The status of a single evaluation list item.
enum EvaluationItemStatus {
  pending,
  saved,
  submitted,
  unknown,
}

/// Represents a row in the official evaluation jqGrid table.
class EvaluationListItem {
  final String safeId;
  final String rowId;
  final String fingerprint;
  final bool selected;
  final EvaluationItemStatus status;
  final int page;

  const EvaluationListItem({
    required this.safeId,
    required this.rowId,
    required this.fingerprint,
    required this.selected,
    required this.status,
    required this.page,
  });

  factory EvaluationListItem.fromJson(Map<String, dynamic> json) {
    EvaluationItemStatus parseStatus(String? s) {
      if (s == null) return EvaluationItemStatus.unknown;
      final lower = s.toLowerCase();
      if (lower.contains('未评') || lower.contains('pending')) {
        return EvaluationItemStatus.pending;
      }
      if (lower.contains('已评') || lower.contains('已保存') || lower.contains('saved')) {
        return EvaluationItemStatus.saved;
      }
      if (lower.contains('已提交') || lower.contains('submitted')) {
        return EvaluationItemStatus.submitted;
      }
      return EvaluationItemStatus.unknown;
    }

    return EvaluationListItem(
      safeId: json['safeId']?.toString() ?? '',
      rowId: json['rowId']?.toString() ?? '',
      fingerprint: json['fingerprint']?.toString() ?? '',
      selected: json['selected'] == true,
      status: parseStatus(json['status']?.toString()),
      page: (json['page'] as num?)?.toInt() ?? 1,
    );
  }
}

/// Snapshot of the automation process at any given moment.
class EvaluationAutomationProgress {
  final EvaluationAutomationState state;
  final int completedCount;
  final int? totalCount;
  final String? currentItemLabel;
  final String? message;
  final bool pauseRequested;
  final String? error;

  const EvaluationAutomationProgress({
    this.state = EvaluationAutomationState.idle,
    this.completedCount = 0,
    this.totalCount,
    this.currentItemLabel,
    this.message,
    this.pauseRequested = false,
    this.error,
  });

  EvaluationAutomationProgress copyWith({
    EvaluationAutomationState? state,
    int? completedCount,
    int? totalCount,
    String? currentItemLabel,
    String? message,
    bool? pauseRequested,
    String? error,
    bool clearError = false,
  }) {
    return EvaluationAutomationProgress(
      state: state ?? this.state,
      completedCount: completedCount ?? this.completedCount,
      totalCount: totalCount ?? this.totalCount,
      currentItemLabel: currentItemLabel ?? this.currentItemLabel,
      message: message ?? this.message,
      pauseRequested: pauseRequested ?? this.pauseRequested,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// A snapshot taken before or after clicking the save button.
class EvaluationSaveSnapshot {
  final String currentFingerprint;
  final int savedCount;
  final String? rowStatus;
  final int successMarkerCount;

  const EvaluationSaveSnapshot({
    required this.currentFingerprint,
    required this.savedCount,
    this.rowStatus,
    required this.successMarkerCount,
  });

  factory EvaluationSaveSnapshot.fromJson(Map<String, dynamic> json) {
    return EvaluationSaveSnapshot(
      currentFingerprint: json['fingerprint']?.toString() ?? '',
      savedCount: (json['savedCount'] as num?)?.toInt() ?? 0,
      rowStatus: json['rowStatus']?.toString(),
      successMarkerCount: (json['successMarkerCount'] as num?)?.toInt() ?? 0,
    );
  }
}
