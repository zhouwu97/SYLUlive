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
      builder: (_) => DeviceJobPermissionSheet(job: job),
    );
    return allowed ?? false;
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('允许读取本地缓存？', style: TextStyle(fontSize: 18)),
          const SizedBox(height: 12),
          Text(_toolLabel(job.toolName)),
          const SizedBox(height: 6),
          Text(_dataLabel(job.requiredDataTypes)),
          const SizedBox(height: 20),
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
                child: const Text('允许本次'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String _toolLabel(String toolName) => switch (toolName) {
        'device.academic.get_cached_overview' => '校园 Agent 请求成绩缓存概览',
        'device.schedule.get_cached_week' => '校园 Agent 请求本周课表',
        'device.academic.get_credit_summary' => '校园 Agent 请求学分汇总',
        'device.erke.get_cached_overview' => '校园 Agent 请求二课概览',
        _ => '校园 Agent 请求本地数据',
      };

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
