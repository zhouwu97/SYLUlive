import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../application/academic_session_controller.dart';
import '../../../providers/edu_provider.dart';

/// 两个入口共用确认与身份检查，防止弹窗期间切换账号后误解绑另一身份。
Future<bool> confirmAcademicUnbind(BuildContext context) async {
  final session = context.read<AcademicSessionController>();
  final identity = session.identity;
  if (identity == null) return false;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('解绑${identity.providerId.displayName}？'),
      content: Text(
          '将移除学号 ${identity.studentId} 的教务配置及本机密码、会话和缓存。App 登录账号和其他教务账号不变，云端配置将在联网后同步。'),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消')),
        FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('解绑教务')),
      ],
    ),
  );
  if (confirmed != true || !context.mounted || session.identity != identity) {
    return false;
  }
  final result = await context.read<EduProvider>().unbind();
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
      result.success
          ? '已解绑${identity.providerId.displayName}，App 登录账号不变'
          : result.errorMessage ?? '解绑未完成，请重试',
    )));
  }
  return result.success;
}
