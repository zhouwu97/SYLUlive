import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// 页面构建失败时显示的用户级兜底，不使用 Flutter 默认灰块错误页。
class AppCrashFallback extends StatelessWidget {
  const AppCrashFallback({
    super.key,
    required this.details,
    this.onRetry,
    this.diagnosticId,
  });

  final FlutterErrorDetails details;
  final VoidCallback? onRetry;
  final String? diagnosticId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.scaffoldBackgroundColor,
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.warning_amber_rounded,
                  size: 42,
                  color: theme.colorScheme.error,
                  semanticLabel: '页面加载失败',
                ),
                const SizedBox(height: 14),
                Text('页面暂时无法显示', style: theme.textTheme.titleLarge),
                const SizedBox(height: 8),
                Text(
                  '可以重试当前页面；如果问题持续，请复制诊断编号反馈。',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium,
                ),
                if (kDebugMode && diagnosticId != null) ...[
                  const SizedBox(height: 8),
                  SelectableText(
                    '诊断编号：$diagnosticId',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
                if (onRetry != null) ...[
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('重试'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
