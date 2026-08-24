import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 启动阶段的独立应用根节点。
///
/// appBootstrap 在 MaterialApp 尚未创建前就需要展示恢复壳，因此这里提供
/// 最小的 Material 根，确保方向性、主题和 MaterialLocalizations 已就绪。
class StartupRecoveryApp extends StatelessWidget {
  const StartupRecoveryApp({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: child,
    );
  }
}

/// 启动阶段的最小恢复壳。
///
/// 这个页面不依赖 Provider、Hive 或业务导航，因此本地存储初始化失败时
/// 仍然可以给用户提供重试和诊断入口。
class StartupRecoveryScreen extends StatefulWidget {
  const StartupRecoveryScreen({
    super.key,
    this.error,
    this.stackTrace,
    this.diagnosticText,
    this.onRetry,
    this.onClearNonSensitiveCache,
  });

  final Object? error;
  final StackTrace? stackTrace;
  final String? diagnosticText;
  final Future<void> Function()? onRetry;
  final Future<void> Function()? onClearNonSensitiveCache;

  bool get isRecovering => error != null;

  @override
  State<StartupRecoveryScreen> createState() => _StartupRecoveryScreenState();
}

class _StartupRecoveryScreenState extends State<StartupRecoveryScreen> {
  bool _busy = false;
  String? _actionMessage;

  Future<void> _runAction(
    Future<void> Function()? action, {
    required String successMessage,
  }) async {
    if (_busy || action == null) return;
    setState(() {
      _busy = true;
      _actionMessage = null;
    });
    try {
      await action();
      if (mounted) setState(() => _actionMessage = successMessage);
    } catch (error) {
      if (mounted) {
        setState(() => _actionMessage = '操作失败，请再次尝试：$error');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copyDiagnostics() async {
    final text = widget.diagnosticText ??
        [
          '启动失败',
          '错误：${widget.error ?? '未知'}',
          if (widget.stackTrace != null) '',
          if (widget.stackTrace != null) widget.stackTrace,
        ].join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) setState(() => _actionMessage = '诊断信息已复制');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isRecovery = widget.isRecovering;
    final title = isRecovery ? '应用启动失败' : '正在准备应用';
    final subtitle =
        isRecovery ? '本地数据未能完成初始化。登录凭据和个人数据不会因本页操作被主动清除。' : '正在初始化本地数据，请稍候…';

    return Material(
      color: theme.scaffoldBackgroundColor,
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    isRecovery
                        ? Icons.cloud_off_rounded
                        : Icons.hourglass_top_rounded,
                    size: 48,
                    color: isRecovery
                        ? theme.colorScheme.error
                        : theme.colorScheme.primary,
                    semanticLabel: isRecovery ? '启动失败' : '正在初始化',
                  ),
                  const SizedBox(height: 20),
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    subtitle,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium,
                  ),
                  if (isRecovery) ...[
                    const SizedBox(height: 20),
                    if (kDebugMode && widget.error != null)
                      SelectableText(
                        widget.error.toString(),
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall,
                      ),
                    const SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _busy
                            ? null
                            : () => _runAction(
                                  widget.onRetry,
                                  successMessage: '已提交重试请求',
                                ),
                        icon: const Icon(Icons.refresh_rounded),
                        label: const Text('重试启动'),
                      ),
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _busy
                            ? null
                            : () => _runAction(
                                  widget.onClearNonSensitiveCache,
                                  successMessage: '非敏感缓存已清理，请重试启动',
                                ),
                        icon: const Icon(Icons.cleaning_services_outlined),
                        label: const Text('清理非敏感缓存后重试'),
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextButton.icon(
                      onPressed: _busy ? null : _copyDiagnostics,
                      icon: const Icon(Icons.copy_all_outlined),
                      label: const Text('复制诊断信息'),
                    ),
                  ] else ...[
                    const SizedBox(height: 24),
                    const SizedBox(
                      width: 28,
                      height: 28,
                      child: CircularProgressIndicator(strokeWidth: 3),
                    ),
                  ],
                  if (_busy) ...[
                    const SizedBox(height: 14),
                    const LinearProgressIndicator(),
                  ],
                  if (_actionMessage != null) ...[
                    const SizedBox(height: 14),
                    Text(
                      _actionMessage!,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
