import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/app_update_info.dart';
import '../services/app_update_coordinator.dart';

/// 兼容旧页面的手动检查入口。
///
/// 首页和关于页面过去直接请求 Gitee 并各自维护弹窗；现在统一委托给根级更新
/// 协调器。旧客户端仍可通过既有 Gitee Release 获得桥接版本，新客户端则只信任
/// 服务器下发的 versionCode 策略与 APK 完整性信息。
class UpdateChecker {
  static Future<void> check(
    BuildContext context, {
    bool showNoUpdateToast = false,
    bool manual = false,
  }) async {
    final coordinator = context.read<AppUpdateCoordinator>();
    await coordinator.check(force: true, manual: manual);
    if (!showNoUpdateToast || !context.mounted) return;

    final info = coordinator.info;
    if (coordinator.phase == AppUpdatePhase.allowed &&
        (info == null || info.updateType == AppUpdateType.none)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('当前已经是最新版本')),
      );
    }
  }
}
