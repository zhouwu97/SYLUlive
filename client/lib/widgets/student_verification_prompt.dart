import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import '../screens/edu_screen.dart';
import '../platform/contracts/preferences_store.dart';
import 'app_dialog.dart';

/// 提醒尚未完成学生认证的账号去认证。每个账号只弹一次，取消后不再出现。
abstract final class StudentVerificationPrompt {
  static String shownKey(int userId) => 'student_verification_prompt_shown_$userId';

  /// 首页启动后调用。只在首页位于最上层时弹出，避免叠在协议、更新等弹窗之上；
  /// 本次没能弹出的不记录，下次启动再判断。
  static Future<void> maybeShow(BuildContext context) async {
    final auth = context.read<AuthProvider>();
    final user = auth.user;
    if (!auth.isLoggedIn ||
        user == null ||
        user.isAdmin ||
        user.studentVerified ||
        !user.legalConsentsActive) {
      return;
    }
    final prefs = await AppPreferencesStore.getInstance();
    if (prefs.getBool(shownKey(user.id)) == true) return;
    // 本地资料可能是旧缓存；弹出前以服务器最新的认证状态为准。
    await auth.refreshUser();
    if (!context.mounted ||
        auth.user?.id != user.id ||
        auth.user?.studentVerified != false ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    await prefs.setBool(shownKey(user.id), true);
    if (!context.mounted) return;
    final go = await showAppDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('完成学生认证'),
        content: const Text(
          '试卷库等在校生功能需要先完成学生认证。登录一次教务系统，App 会自动向学校核验你的学号。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('暂不认证'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('去认证'),
          ),
        ],
      ),
    );
    if (go != true || !context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const EduScreen()),
    );
    if (context.mounted) await auth.refreshUser();
  }
}
