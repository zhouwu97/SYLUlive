import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_radius.dart';
import 'ai_quick_action_card.dart';

class AiPersonalEmptyState extends StatelessWidget {
  final bool needsModelConfiguration;
  final VoidCallback onConfigureModel;
  final ValueChanged<String> onActionSelected;

  const AiPersonalEmptyState({
    super.key,
    required this.needsModelConfiguration,
    required this.onConfigureModel,
    required this.onActionSelected,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final quickActions = <(IconData, String, String, String)>[
      (Icons.school_outlined, '我的学业', '计算我的 GPA 和学分情况。', '分析我的学业情况'),
      (Icons.emoji_events_outlined, '竞赛搜索', '搜索近期公开竞赛。', '搜索近期公开竞赛'),
      (Icons.dashboard_outlined, '二课概览', '我还差多少二课分？', '查看我的二课概览'),
      (Icons.fitness_center_outlined, '运动计划', '帮我安排本周运动时间。', '帮我安排本周运动时间'),
    ];

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 28, 16, 24),
      children: [
        if (needsModelConfiguration)
          Container(
            margin: const EdgeInsets.only(bottom: 24),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: AppColors.warningSurfaceLight,
              borderRadius: BorderRadius.circular(AppRadius.md),
              border: Border.all(color: const Color(0xFFF2DDBD), width: 1),
            ),
            child: Row(
              children: [
                const Icon(Icons.info_outline_rounded,
                    size: 20, color: Color(0xFFF97316)),
                const SizedBox(width: 10),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '个人助手尚未完成模型配置',
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF9A3412)),
                      ),
                      SizedBox(height: 2),
                      Text(
                        '配置仅保存在本机，可随时更换',
                        style:
                            TextStyle(fontSize: 11, color: Color(0xFFC2410C)),
                      ),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: onConfigureModel,
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFFF97316),
                    textStyle: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    minimumSize: const Size(0, 32),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                  child: const Text('去配置'),
                ),
              ],
            ),
          ),
        Text(
          '个人助手',
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w700,
            color: colors.onSurface,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          '使用你配置的模型和本机 ToolLoop。\n它和校园 Agent 的服务端 Run、MCP 设备任务是两条不同链路。',
          style: TextStyle(
            color: colors.onSurfaceVariant,
            fontSize: 13,
            height: 1.55,
          ),
        ),
        const SizedBox(height: 28),
        Text(
          '本机能力',
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            color: colors.onSurface,
          ),
        ),
        const SizedBox(height: 12),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            mainAxisExtent: 76,
          ),
          itemCount: quickActions.length,
          itemBuilder: (context, index) {
            final action = quickActions[index];
            return AiQuickActionCard(
              icon: action.$1,
              title: action.$2,
              subtitle: action.$3,
              onTap: () => onActionSelected(action.$4),
            );
          },
        ),
      ],
    );
  }
}
