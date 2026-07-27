import 'personal_data_sync_models.dart';

/// 一键同步的执行阶段，用于界面展示真实进度。
enum PersonalSyncPhase { serverEducation, deviceErke, completed }

/// 单项同步进度；错误详情只保留可展示的短消息。
class PersonalSyncProgress {
  const PersonalSyncProgress({
    required this.dataset,
    required this.phase,
    required this.isRunning,
    this.message,
  });

  final PersonalSyncDataset dataset;
  final PersonalSyncPhase phase;
  final bool isRunning;
  final String? message;
}

typedef PersonalSyncProgressListener = void Function(
    PersonalSyncProgress progress);
