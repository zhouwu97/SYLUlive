import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'app_navigator.dart';

class AppFeedback {
  const AppFeedback._();

  static const Duration _infoDuration = Duration(seconds: 3);
  static const Duration _successDuration = Duration(seconds: 2);
  static const Duration _errorDuration = Duration(seconds: 4);
  static const Duration _actionDuration = Duration(seconds: 6);

  static String dioErrorMessage(
    DioException e, {
    String serviceName = '服务器',
    String fallback = '操作失败',
  }) {
    final data = e.response?.data;
    if (data is Map) {
      final detail = data['detail'] ?? data['error'] ?? data['message'];
      if (detail is Map) {
        final nestedMessage =
            detail['message'] ?? detail['error'] ?? detail['detail'];
        if (nestedMessage != null &&
            nestedMessage.toString().trim().isNotEmpty) {
          return nestedMessage.toString();
        }
      }
      if (detail != null && detail.toString().trim().isNotEmpty) {
        return detail.toString();
      }
    }

    switch (e.response?.statusCode) {
      case 400:
        return '请求参数有误，请检查填写内容';
      case 401:
        return serviceName == '教务服务' ? '教务账号或密码错误' : '登录已过期或账号密码错误';
      case 403:
        return '没有权限执行该操作';
      case 404:
        return '请求的内容不存在或已被删除';
      case 409:
        return '当前内容状态已变化，请刷新后重试';
      case 422:
        return '填写内容不完整，请检查后重试';
      case 429:
        return '操作过于频繁，请稍后再试';
      case 500:
      case 502:
      case 504:
        return '$serviceName暂时不可用，请稍后再试';
      case 503:
        return serviceName == '教务服务'
            ? '学校教务系统会话异常，请稍后重试，不需要重新绑定'
            : '$serviceName暂时不可用，请稍后再试';
    }

    switch (e.type) {
      case DioExceptionType.connectionTimeout:
        return '连接$serviceName超时，请检查网络后重试';
      case DioExceptionType.sendTimeout:
        return '请求发送超时，请检查网络后重试';
      case DioExceptionType.receiveTimeout:
        return '$serviceName响应超时，请稍后再试';
      case DioExceptionType.transformTimeout:
        return '$serviceName响应处理超时，请稍后再试';
      case DioExceptionType.connectionError:
        return '无法连接$serviceName，请检查网络或稍后重试';
      case DioExceptionType.badCertificate:
        return '$serviceName证书异常，请稍后再试';
      case DioExceptionType.cancel:
        return '请求已取消';
      case DioExceptionType.badResponse:
      case DioExceptionType.unknown:
        return e.message?.trim().isNotEmpty == true ? e.message! : fallback;
    }
  }

  /// 统一的普通提示层。优先使用根 messenger，避免提示被局部 Scaffold
  /// 或宽屏分栏吸附到不同位置；测试或局部宿主没有根 messenger 时才回退到 context。
  static void info(String message, {BuildContext? context}) {
    _show(
      message,
      context: context,
      kind: _FeedbackKind.info,
      duration: _infoDuration,
    );
  }

  static void success(String message, {BuildContext? context}) {
    _show(
      message,
      context: context,
      kind: _FeedbackKind.success,
      duration: _successDuration,
    );
  }

  static void error(String message, {BuildContext? context}) {
    _show(
      message,
      context: context,
      kind: _FeedbackKind.error,
      duration: _errorDuration,
    );
  }

  static void action(
    String message, {
    required String actionLabel,
    required VoidCallback onAction,
    BuildContext? context,
  }) {
    _show(
      message,
      context: context,
      kind: _FeedbackKind.action,
      duration: _actionDuration,
      actionLabel: actionLabel,
      onAction: onAction,
    );
  }

  /// 兼容旧调用点；业务代码应迁移到 info/success/error/action。
  static void showSnackBar(
    BuildContext context,
    String message, {
    bool isError = false,
  }) {
    if (isError) {
      error(message, context: context);
    } else {
      info(message, context: context);
    }
  }

  static void showGlobalToast(String message, {bool isError = false}) {
    if (isError) {
      error(message);
    } else {
      info(message);
    }
  }

  static void _show(
    String message, {
    BuildContext? context,
    required _FeedbackKind kind,
    required Duration duration,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    final messenger = scaffoldMessengerKey.currentState ??
        (context == null ? null : ScaffoldMessenger.maybeOf(context));
    if (messenger == null || message.trim().isEmpty) return;

    final theme = context == null ? null : Theme.of(context);
    final colors = theme?.colorScheme;
    final palette = _FeedbackPalette.from(kind, colors);
    final content = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(palette.icon, size: 18, color: palette.foreground),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              message,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: palette.foreground),
            ),
          ),
        ],
      ),
    );
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: content,
          duration: duration,
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          backgroundColor: palette.background,
          action: actionLabel == null || onAction == null
              ? null
              : SnackBarAction(
                  label: actionLabel,
                  textColor: palette.foreground,
                  onPressed: onAction,
                ),
        ),
      );
  }

  static Future<void> showErrorDialog(
    BuildContext context, {
    required String title,
    required String message,
  }) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Row(
          children: [
            Icon(Icons.error_outline, color: Colors.red.shade400),
            const SizedBox(width: 8),
            Text(title),
          ],
        ),
        content: Text(message, style: const TextStyle(height: 1.45)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  static Future<bool> confirmDanger(
    BuildContext context, {
    required String title,
    required String message,
    String confirmText = '确认删除',
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Text(title),
        content: Text(message, style: const TextStyle(height: 1.45)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(confirmText),
          ),
        ],
      ),
    );
    return ok == true;
  }
}

enum _FeedbackKind { info, success, error, action }

class _FeedbackPalette {
  const _FeedbackPalette({
    required this.background,
    required this.foreground,
    required this.icon,
  });

  final Color background;
  final Color foreground;
  final IconData icon;

  factory _FeedbackPalette.from(
    _FeedbackKind kind,
    ColorScheme? colors,
  ) {
    final scheme = colors ?? ColorScheme.fromSeed(seedColor: Colors.teal);
    switch (kind) {
      case _FeedbackKind.info:
        return _FeedbackPalette(
          background: scheme.secondaryContainer,
          foreground: scheme.onSecondaryContainer,
          icon: Icons.info_outline_rounded,
        );
      case _FeedbackKind.success:
        return _FeedbackPalette(
          background: scheme.tertiaryContainer,
          foreground: scheme.onTertiaryContainer,
          icon: Icons.check_circle_outline_rounded,
        );
      case _FeedbackKind.error:
        return _FeedbackPalette(
          background: scheme.errorContainer,
          foreground: scheme.onErrorContainer,
          icon: Icons.error_outline_rounded,
        );
      case _FeedbackKind.action:
        return _FeedbackPalette(
          background: scheme.inverseSurface,
          foreground: scheme.onInverseSurface,
          icon: Icons.touch_app_outlined,
        );
    }
  }
}
