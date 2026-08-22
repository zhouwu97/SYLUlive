import 'package:flutter/material.dart';

import '../../models/ai_quick_prompt.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_radius.dart';

class AiSuggestedPrompt {
  const AiSuggestedPrompt({
    required this.title,
    required this.subtitle,
    required this.prompt,
  });

  final String title;
  final String subtitle;
  final String prompt;
}

class AiPublicEmptyState extends StatelessWidget {
  final bool chatEnabled;
  final List<AiQuickPrompt> quickPrompts;
  final List<AiSuggestedPrompt> suggestedPrompts;
  final ValueChanged<String>? onPromptSelected;
  final VoidCallback? onRefreshPrompts;
  final Widget? footer;

  const AiPublicEmptyState({
    super.key,
    required this.chatEnabled,
    required this.quickPrompts,
    this.suggestedPrompts = const <AiSuggestedPrompt>[],
    this.onPromptSelected,
    this.onRefreshPrompts,
    this.footer,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 28, 16, 24),
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              chatEnabled ? '今天想让 Agent 帮你做什么？' : '基础设施测试中',
              style: TextStyle(
                color: colors.onSurface,
                fontSize: 22,
                height: 1.25,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              '它会先查学校资料和已授权快照；\n只有数据确实缺失或过期时，才会请求你的手机继续完成。',
              style: TextStyle(
                color: colors.onSurfaceVariant,
                fontSize: 13,
                height: 1.55,
              ),
            ),
            const SizedBox(height: 28),
            Text(
              '常用能力',
              style: TextStyle(
                color: colors.onSurface,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            GridView.count(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisCount: 2,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 1.62,
              children: [
                _promptCard('本周空闲', '结合课表找可安排时间', '这周哪几天下午比较空？',
                    Icons.event_available_outlined),
                _promptCard('学业风险', '成绩学分综合分析', '分析我的学业情况，找出主要风险并给出改进建议',
                    Icons.insights_outlined),
                _promptCard('近期竞赛', '公开赛事和截止时间', '近期有哪些适合我的竞赛？',
                    Icons.emoji_events_outlined),
                _promptCard('学校政策', '办事规则与官方资料', '学校关于补考和重修的规定是什么？',
                    Icons.menu_book_outlined),
              ],
            ),
          ],
        ),
        if (footer != null) footer!,
      ],
    );
  }

  Widget _promptCard(
      String title, String subtitle, String prompt, IconData icon) {
    return Builder(
      builder: (context) => Semantics(
        button: true,
        label: '$title：$subtitle',
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: chatEnabled ? () => onPromptSelected?.call(prompt) : null,
            borderRadius: BorderRadius.circular(AppRadius.md),
            child: Ink(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).brightness == Brightness.dark
                    ? AppColors.surfaceSecondaryDark
                    : Colors.white,
                borderRadius: BorderRadius.circular(AppRadius.md),
                border: Border.all(
                  color: Theme.of(context).brightness == Brightness.dark
                      ? AppColors.borderNormalDark
                      : AppColors.borderNormalLight,
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(icon, size: 19, color: AppColors.brandPrimary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title,
                            style: TextStyle(
                                color: Theme.of(context).colorScheme.onSurface,
                                fontSize: 13,
                                fontWeight: FontWeight.w700)),
                        const SizedBox(height: 4),
                        Text(subtitle,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 11,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                                height: 1.35)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
