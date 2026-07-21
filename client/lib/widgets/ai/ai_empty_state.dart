import 'package:flutter/material.dart';

import '../campus/campus_theme.dart';
import 'ai_suggestion_chip.dart';

class AiEmptyState extends StatelessWidget {
  final bool chatEnabled;
  final List<String> quickPrompts;
  final ValueChanged<String>? onPromptSelected;

  const AiEmptyState({
    super.key,
    required this.chatEnabled,
    required this.quickPrompts,
    this.onPromptSelected,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 44, 24, 24),
      child: Column(
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: CampusTheme.primaryLight,
              borderRadius: BorderRadius.circular(22),
            ),
            child: const Icon(
              Icons.auto_awesome_rounded,
              color: CampusTheme.primary,
              size: 32,
            ),
          ),
          const SizedBox(height: 18),
          Text(
            chatEnabled ? '有什么校园问题想问？' : '基础设施测试中',
            style: TextStyle(
              color: colors.onSurface,
              fontSize: 20,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            chatEnabled ? '可查询已开放的校园政策\n与本机课表缓存' : '当前仅验证入口、权限与配额展示，\n暂不发送真实问题。',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: colors.onSurfaceVariant,
              fontSize: 13,
              height: 1.45,
            ),
          ),
          if (quickPrompts.isNotEmpty) ...[
            const SizedBox(height: 22),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 10,
              runSpacing: 10,
              children: quickPrompts
                  .take(4)
                  .map(
                    (prompt) => AiSuggestionChip(
                      label: prompt,
                      onTap: () => onPromptSelected?.call(prompt),
                    ),
                  )
                  .toList(),
            ),
          ],
        ],
      ),
    );
  }
}
