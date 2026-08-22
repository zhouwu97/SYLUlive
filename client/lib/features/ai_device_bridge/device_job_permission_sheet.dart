import 'package:flutter/material.dart';

import 'device_job_models.dart';

/// 每次设备任务均在前台要求确认，后台推送不会绕过用户对本地缓存的控制。
class DeviceJobPermissionSheet extends StatelessWidget {
  const DeviceJobPermissionSheet({super.key, required this.job});

  final DeviceToolJob job;

  static Future<bool> request(BuildContext context, DeviceToolJob job) async {
    final allowed = await showModalBottomSheet<bool>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (_) => DeviceJobPermissionSheet(job: job),
    );
    return allowed ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: colors.outlineVariant,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            '校园 Agent 想在你的设备上执行一次操作',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text(
            '为了回答当前问题，Agent 需要从设备读取最小化摘要。不会读取密码、Cookie、Token 或设备标识。',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 20),
          _ActionRow(
            icon: Icons.sync_rounded,
            title: _operationLabel(job.toolName),
            detail: _dataLabel(job.requiredDataTypes),
          ),
          const SizedBox(height: 10),
          const _ActionRow(
            icon: Icons.lock_outline_rounded,
            title: '只回传本次问题所需的摘要',
            detail: '设备原始数据不会直接展示给 Agent',
          ),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('拒绝'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('允许并执行'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String _operationLabel(String toolName) =>
      toolName.contains('ensure_fresh') ? '刷新后读取设备数据' : '读取设备本地缓存';

  static String _dataLabel(List<String> types) {
    final labels = types.map((type) => switch (type) {
          'academic' => '成绩',
          'schedule' => '课表',
          'erke' => '二课',
          _ => '个人数据',
        });
    return '仅返回本次问题所需的${labels.join('、')}摘要';
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.icon,
    required this.title,
    required this.detail,
  });

  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 22, color: colors.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 3),
                Text(detail, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
