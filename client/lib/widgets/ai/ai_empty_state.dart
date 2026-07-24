import 'package:flutter/material.dart';

import '../campus/campus_theme.dart';
import 'ai_quick_action_card.dart';

class AiPublicEmptyState extends StatelessWidget {
  final bool chatEnabled;
  final List<String> quickPrompts;
  final ValueChanged<String>? onPromptSelected;
  final VoidCallback? onRefreshPrompts;

  const AiPublicEmptyState({
    super.key,
    required this.chatEnabled,
    required this.quickPrompts,
    this.onPromptSelected,
    this.onRefreshPrompts,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 24),
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
                  style: const TextStyle(
                    color: Color(0xFF20272B),
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  chatEnabled ? '可查询已开放的校园政策\n与本机课表缓存' : '当前仅验证入口、权限与配额展示，\n暂不发送真实问题。',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xFF7B8388),
                    fontSize: 13,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
          if (quickPrompts.isNotEmpty) ...[
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  '常用问题',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF20272B),
                  ),
                ),
                if (onRefreshPrompts != null)
                  TextButton(
                    onPressed: onRefreshPrompts,
                    style: TextButton.styleFrom(
                      foregroundColor: const Color(0xFF7B8388),
                      textStyle: const TextStyle(fontSize: 13),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(0, 32),
                    ),
                    child: const Text('换一批'),
                  ),
              ],
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
              itemCount: quickPrompts.length > 4 ? 4 : quickPrompts.length,
              itemBuilder: (context, index) {
                final prompt = quickPrompts[index];
                final categories = ['学业考试', '教学管理', '奖助评优', '校园日程'];
                final category = categories[index % categories.length];
                return AiPromptCard(
                  category: category,
                  prompt: prompt,
                  onTap: () => onPromptSelected?.call(prompt),
                );
              },
            ),
          ],
        ],
      ),
    );
  }
}
