import 'package:flutter/material.dart';

import '../../models/ai_run_event.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_radius.dart';

/// 单次 Agent 授权卡。长期策略只能从权限 Bottom Sheet 修改。
class AiAgentPermissionCard extends StatelessWidget {
  const AiAgentPermissionCard({
    super.key,
    required this.event,
    this.onDeny,
    this.onAllowOnce,
    this.submitting = false,
  });

  final AiRunEvent event;
  final VoidCallback? onDeny;
  final VoidCallback? onAllowOnce;
  final bool submitting;

  @override
  Widget build(BuildContext context) {
    final label = _datasetLabel(event.datasets);
    return Container(
      key: const ValueKey('ai-agent-permission-card'),
      margin: const EdgeInsets.only(top: 0, bottom: 12),
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
      decoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.dark
            ? AppColors.warningSurfaceDark
            : const Color(0xFFFFFAF1),
        border: Border.all(color: const Color(0xFFF2DDBD)),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.shield_outlined,
                  size: 19, color: AppColors.warning),
              const SizedBox(width: 8),
              Expanded(
                child: Text('$label 数据需要更新',
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w700)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            event.consentReason.trim().isEmpty
                ? 'Agent 需要让你的设备读取 $label 数据，完成后会自动继续当前回答。'
                : event.consentReason.trim(),
            style: const TextStyle(fontSize: 12.5, height: 1.45),
          ),
          const SizedBox(height: 10),
          _InfoRow(label: '现有$label数据', value: '已授权快照'),
          const _InfoRow(label: '本次要求', value: '最新数据'),
          const SizedBox(height: 8),
          const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.lock_outline_rounded,
                  size: 15, color: AppColors.brandPrimary),
              SizedBox(width: 6),
              Expanded(
                  child: Text('不上传密码、Cookie 或 Token',
                      style: TextStyle(
                          fontSize: 11.5,
                          color: AppColors.textSecondaryLight))),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: submitting ? null : onDeny,
                child: const Text('暂不允许'),
              ),
              const SizedBox(width: 4),
              FilledButton.icon(
                onPressed: submitting ? null : onAllowOnce,
                icon: submitting
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.check_rounded, size: 16),
                label: Text(submitting ? '正在继续' : '允许本次'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String _datasetLabel(List<String> datasets) {
    if (datasets.contains('grades') || datasets.contains('academic')) {
      return '成绩';
    }
    if (datasets.contains('schedule')) return '课表';
    if (datasets.contains('erke')) return '二课';
    return '校园数据';
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Expanded(
              child: Text(label,
                  style: const TextStyle(
                      fontSize: 11.5, color: AppColors.textSecondaryLight))),
          Text(value,
              style:
                  const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}
