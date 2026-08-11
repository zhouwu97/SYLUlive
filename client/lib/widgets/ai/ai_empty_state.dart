import 'package:flutter/material.dart';

import '../../models/ai_quick_prompt.dart';
import 'ai_quick_action_card.dart';

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

  const AiPublicEmptyState({
    super.key,
    required this.chatEnabled,
    required this.quickPrompts,
    this.suggestedPrompts = const <AiSuggestedPrompt>[],
    this.onPromptSelected,
    this.onRefreshPrompts,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final visibleQuickPrompts = quickPrompts.take(4).toList(growable: false);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 16),
          Container(
            alignment: Alignment.center,
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    color: colors.primaryContainer,
                    borderRadius: BorderRadius.circular(22),
                  ),
                  child: Icon(
                    Icons.auto_awesome_rounded,
                    color: colors.primary,
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
                  chatEnabled
                      ? '可查询已开放的校园政策\n与本机课表缓存'
                      : '当前仅验证入口、权限与配额展示，\n暂不发送真实问题。',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: colors.onSurfaceVariant,
                    fontSize: 13,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
          if (suggestedPrompts.isNotEmpty) ...[
            const SizedBox(height: 16),
            _AiEmptySectionTitle(title: '快捷能力', colors: colors),
            const SizedBox(height: 12),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                mainAxisExtent: 72,
              ),
              itemCount: suggestedPrompts.length,
              itemBuilder: (context, index) {
                final card = suggestedPrompts[index];
                return AiPromptCard(
                  category: card.title,
                  prompt: card.subtitle,
                  onTap: () => onPromptSelected?.call(card.prompt),
                );
              },
            ),
          ],
          if (visibleQuickPrompts.isNotEmpty) ...[
            const SizedBox(height: 16),
            _AiEmptySectionTitle(
              title: '猜你想问',
              colors: colors,
              trailing: onRefreshPrompts == null
                  ? null
                  : TextButton(
                      onPressed: onRefreshPrompts,
                      style: TextButton.styleFrom(
                        foregroundColor: colors.onSurfaceVariant,
                        textStyle: const TextStyle(fontSize: 13),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: const Size(0, 32),
                      ),
                      child: const Text('换一批'),
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
                mainAxisExtent: 72,
              ),
              itemCount: visibleQuickPrompts.length,
              itemBuilder: (context, index) {
                final prompt = visibleQuickPrompts[index];
                return AiPromptCard(
                  category: prompt.category,
                  prompt: prompt.question,
                  onTap: () => onPromptSelected?.call(prompt.question),
                );
              },
            ),
          ],
        ],
      ),
    );
  }
}

class _AiEmptySectionTitle extends StatelessWidget {
  const _AiEmptySectionTitle({
    required this.title,
    required this.colors,
    this.trailing,
  });

  final String title;
  final ColorScheme colors;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: colors.onSurface,
          ),
        ),
        if (trailing != null) trailing!,
      ],
    );
  }
}
