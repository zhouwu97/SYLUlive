import 'package:flutter/material.dart';

enum ExamPaperAccessGuideType { login, eduVerification }

class ExamPaperAccessGuide extends StatelessWidget {
  final ExamPaperAccessGuideType type;
  final VoidCallback onAction;

  const ExamPaperAccessGuide({
    super.key,
    required this.type,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final isLogin = type == ExamPaperAccessGuideType.login;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Card(
          margin: const EdgeInsets.all(24),
          elevation: 0,
          color: Theme.of(context)
              .colorScheme
              .surfaceContainerHighest
              .withValues(alpha: 0.72),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    color: Theme.of(context)
                        .colorScheme
                        .primary
                        .withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    isLogin
                        ? Icons.login_rounded
                        : Icons.verified_user_outlined,
                    size: 34,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  isLogin ? '登录后使用试卷库' : '完成教务认证后使用',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(height: 10),
                Text(
                  isLogin
                      ? '登录后可浏览、预览、下载并投稿历年试卷。'
                      : '为保护校内资料，仅完成教务认证的普通用户可以访问；管理员不受此限制。',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        height: 1.5,
                      ),
                ),
                const SizedBox(height: 22),
                FilledButton.icon(
                  onPressed: onAction,
                  icon: Icon(isLogin ? Icons.login : Icons.school_outlined),
                  label: Text(isLogin ? '去登录' : '去认证'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
