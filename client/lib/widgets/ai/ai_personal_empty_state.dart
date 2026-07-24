import 'package:flutter/material.dart';
import '../../config/beta_release_policy.dart';
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
    final quickActions = <(IconData, String, String)>[
      (Icons.school_outlined, '我的学业', '计算我的 GPA 和学分情况。'),
      (Icons.emoji_events_outlined, '竞赛搜索', '搜索近期公开竞赛。'),
      (Icons.fitness_center_outlined, '运动计划', '帮我安排本周运动时间。'),
      if (BetaReleasePolicy.aiGraduationAssistant)
        (Icons.fact_check_outlined, '毕业清单', '我的毕业要求还有哪些未完成？'),
      (Icons.dashboard_outlined, '二课概览', '我还差多少二课分？'),
    ];

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 20),
      children: [
        if (needsModelConfiguration)
          Container(
            margin: const EdgeInsets.only(bottom: 24),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: const Color(0xFFFFF7ED), // very light orange
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFFFEDD5), width: 1),
            ),
            child: Row(
              children: [
                const Icon(Icons.info_outline_rounded,
                    size: 20, color: Color(0xFFF97316)),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: const [
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
                        style: TextStyle(
                            fontSize: 11, color: Color(0xFFC2410C)),
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
        const Text(
          '你的校园助理',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: Color(0xFF20272B),
          ),
        ),
        const SizedBox(height: 16),
        AiPrimaryActionCard(
          icon: Icons.today_outlined,
          title: '今天安排',
          subtitle: '我今天有什么课？',
          onTap: () => onActionSelected('我今天有什么课？'),
        ),
        const SizedBox(height: 24),
        const Text(
          '快捷能力',
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: Color(0xFF20272B),
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
            mainAxisExtent: 66,
          ),
          itemCount: quickActions.length,
          itemBuilder: (context, index) {
            final action = quickActions[index];
            return AiQuickActionCard(
              icon: action.$1,
              title: action.$2,
              subtitle: action.$3, // Used as brief description
              onTap: () => onActionSelected(action.$3),
            );
          },
        ),
      ],
    );
  }
}
