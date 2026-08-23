import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../../services/ai_personal_data_permission_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_motion.dart';
import '../../theme/app_radius.dart';

/// 普通用户只选择 Agent 的工作方式；内部 scope 由服务端原子写入。
class AiAgentPermissionSheet extends StatefulWidget {
  const AiAgentPermissionSheet({super.key, required this.dio});

  final Dio dio;

  static Future<void> show(BuildContext context, Dio dio) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.28),
      builder: (_) => AiAgentPermissionSheet(dio: dio),
    );
  }

  @override
  State<AiAgentPermissionSheet> createState() => _AiAgentPermissionSheetState();
}

class _AiAgentPermissionSheetState extends State<AiAgentPermissionSheet> {
  late final AiPersonalDataPermissionService _service;
  late Future<AiAgentPermissionMode> _future;
  AiAgentPermissionMode? _mode;
  String? _errorMessage;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _service = AiPersonalDataPermissionService(widget.dio);
    _future = _load();
  }

  Future<AiAgentPermissionMode> _load() async {
    try {
      final mode = await _service.getMode();
      if (mounted) {
        setState(() {
          _mode = mode;
          _errorMessage = null;
        });
      }
      return mode;
    } on AiPersonalDataPermissionException catch (error) {
      if (mounted) setState(() => _errorMessage = error.message);
      rethrow;
    }
  }

  Future<void> _setMode(AiAgentPermissionMode mode) async {
    if (_saving || _mode == mode) return;
    setState(() => _saving = true);
    try {
      final updated = await _service.setMode(mode);
      if (mounted) setState(() => _mode = updated);
    } on AiPersonalDataPermissionException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error.message)),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Container(
      constraints: const BoxConstraints(maxHeight: 460),
      decoration: BoxDecoration(
        color: isDark ? AppColors.surfaceSecondaryDark : Colors.white,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppRadius.sheet),
        ),
      ),
      child: FutureBuilder<AiAgentPermissionMode>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const SizedBox(
              height: 300,
              child: Center(child: CircularProgressIndicator()),
            );
          }
          if (snapshot.hasError || _mode == null) {
            return _buildError(_errorMessage);
          }
          return _buildContent(context, isDark);
        },
      ),
    );
  }

  Widget _buildContent(BuildContext context, bool isDark) {
    final mode = _mode!;
    final colors = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 36,
          height: 4,
          margin: const EdgeInsets.only(top: 10, bottom: 6),
          decoration: BoxDecoration(
            color: colors.outlineVariant,
            borderRadius: BorderRadius.circular(AppRadius.pill),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 16, 12),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: isDark
                      ? colors.primaryContainer
                      : AppColors.brandSurfaceLight,
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                child: Icon(Icons.shield_outlined, color: colors.primary),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Agent 数据访问',
                        style: TextStyle(
                            fontSize: 17, fontWeight: FontWeight.w700)),
                    SizedBox(height: 3),
                    Text('选择它使用个人校园数据的方式',
                        style: TextStyle(fontSize: 12, height: 1.4)),
                  ],
                ),
              ),
              IconButton(
                tooltip: '关闭权限设置',
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: Column(
            children: [
              _ModeOption(
                selected: mode == AiAgentPermissionMode.ask,
                enabled: !_saving,
                onTap: () => _setMode(AiAgentPermissionMode.ask),
                title: '每次询问',
                detail: '使用个人校园数据前先询问我',
              ),
              const SizedBox(height: 8),
              _ModeOption(
                selected: mode == AiAgentPermissionMode.trusted,
                enabled: !_saving,
                onTap: () => _setMode(AiAgentPermissionMode.trusted),
                title: '完全信任',
                detail: '自动完成任务需要的数据读取和更新',
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '发帖、私信、删除、修改资料和账号操作仍会单独确认。',
                  style: TextStyle(
                    color: colors.onSurfaceVariant,
                    fontSize: 11.5,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildError(String? message) {
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      height: 300,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.cloud_off_outlined, size: 32, color: colors.primary),
            const SizedBox(height: 12),
            const Text(
              '暂时读取不到 Agent 权限',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              message ?? '请检查登录状态或网络连接后重试。',
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: () => setState(() {
                _mode = null;
                _errorMessage = null;
                _future = _load();
              }),
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('重新加载权限'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModeOption extends StatelessWidget {
  const _ModeOption({
    required this.selected,
    required this.enabled,
    required this.onTap,
    required this.title,
    required this.detail,
  });

  final bool selected;
  final bool enabled;
  final VoidCallback onTap;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      label: '$title。$detail',
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: AnimatedContainer(
          duration: AppMotion.duration(context, AppMotion.fast),
          constraints: const BoxConstraints(minHeight: 64),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: selected
                ? colors.primary.withValues(alpha: 0.08)
                : colors.surfaceContainerHighest.withValues(alpha: 0.35),
            border: Border.all(
              color: selected ? colors.primary : colors.outlineVariant,
            ),
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          child: Row(
            children: [
              Icon(
                selected
                    ? Icons.radio_button_checked_rounded
                    : Icons.radio_button_unchecked_rounded,
                color: selected ? colors.primary : colors.outline,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(detail,
                        style: TextStyle(
                            fontSize: 11, color: colors.onSurfaceVariant)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
