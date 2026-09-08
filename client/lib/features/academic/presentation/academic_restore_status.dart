import 'dart:async';
import 'package:flutter/material.dart';

/// 身份尚未确认不能显示空课表，但等待必须有明确的结束和重试入口。
class AcademicRestoreStatus extends StatefulWidget {
  const AcademicRestoreStatus({super.key, required this.onRetry, this.error});

  final Future<void> Function() onRetry;
  final String? error;

  @override
  State<AcademicRestoreStatus> createState() => _AcademicRestoreStatusState();
}

class _AcademicRestoreStatusState extends State<AcademicRestoreStatus> {
  Timer? _deadline;
  bool _timedOut = false;
  bool _retrying = false;
  String? _retryError;

  @override
  void initState() {
    super.initState();
    _startDeadline();
  }

  void _startDeadline() {
    _deadline?.cancel();
    _deadline = Timer(const Duration(seconds: 15), () {
      if (mounted) setState(() => _timedOut = true);
    });
  }

  Future<void> _retry() async {
    if (_retrying) return;
    setState(() {
      _retrying = true;
      _timedOut = false;
      _retryError = null;
    });
    _startDeadline();
    try {
      await widget.onRetry().timeout(const Duration(seconds: 15));
    } catch (_) {
      if (mounted) _retryError = '恢复暂未完成，请检查网络或稍后重试';
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  @override
  void dispose() {
    _deadline?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final failure =
        !_retrying && (widget.error != null || _retryError != null) ||
            _timedOut;
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(failure ? Icons.sync_problem_rounded : Icons.sync_rounded,
            size: 32, color: colors.onSurfaceVariant),
        const SizedBox(height: 14),
        Text(failure ? '课表恢复暂未完成' : '正在恢复本机课表状态',
            textAlign: TextAlign.center,
            style: TextStyle(
                color: colors.onSurface,
                fontSize: 16,
                fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        Text(
            failure
                ? (_retryError ??
                    widget.error ??
                    '等待时间较长，请检查网络后重试。已保存的课表仍保留在本机。')
                : '正在确认当前教务账号并读取本机课表',
            textAlign: TextAlign.center,
            style: TextStyle(color: colors.onSurfaceVariant, fontSize: 13)),
        if (failure) ...[
          const SizedBox(height: 16),
          OutlinedButton(
              onPressed: _retrying ? null : _retry, child: const Text('重试恢复')),
        ],
      ]),
    );
  }
}
