import 'package:flutter/material.dart';

import '../providers/auth_provider.dart';
import '../services/publish_session_scope.dart';

/// 安全操作弹层属于打开时的账号；切号或降权后立即隐藏旧资料和操作入口。
class SecuritySessionGuard extends StatelessWidget {
  const SecuritySessionGuard(
      {super.key,
      required this.auth,
      required this.session,
      required this.child,
      this.requireAdmin = false,
      this.requireSuperAdmin = false,
      this.dialog = true});

  final AuthProvider auth;
  final PublishSessionScope session;
  final Widget child;
  final bool requireAdmin;
  final bool requireSuperAdmin;
  final bool dialog;

  static bool owns(AuthProvider auth, PublishSessionScope session,
          {bool requireAdmin = false, bool requireSuperAdmin = false}) =>
      auth.isLoggedIn &&
      session.owns(
          userId: auth.user?.id, sessionEpoch: auth.accountSessionEpoch) &&
      (!requireAdmin || auth.user?.isAdmin == true) &&
      (!requireSuperAdmin || auth.user?.isSuperAdmin == true);

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: auth,
        builder: (context, _) {
          if (owns(auth, session,
              requireAdmin: requireAdmin,
              requireSuperAdmin: requireSuperAdmin)) {
            return Theme(
                data: Theme.of(context)
                    .copyWith(visualDensity: VisualDensity.standard),
                child: child);
          }
          final close = TextButton(
              style:
                  TextButton.styleFrom(visualDensity: VisualDensity.standard),
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'));
          if (dialog) {
            return AlertDialog(
                title: const Text('登录状态或权限已变化'),
                content: const Text('请关闭后重新打开安全页面。'),
                actions: [close]);
          }
          return SafeArea(
              child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const Text('登录状态或权限已变化，请重新打开安全页面。'),
                    close,
                  ])));
        },
      );
}
