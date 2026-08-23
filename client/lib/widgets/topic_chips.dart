import 'package:flutter/material.dart';

import '../models/topic.dart';
import '../screens/search_results_screen.dart';
import '../theme/app_colors.dart';

/// 帖子正文后的话题展示。空列表不占位，首页默认只展示前三个。
class PostTopicChips extends StatelessWidget {
  final List<Topic> topics;
  final int maxTopics;

  const PostTopicChips({
    super.key,
    required this.topics,
    this.maxTopics = 3,
  });

  @override
  Widget build(BuildContext context) {
    if (topics.isEmpty) return const SizedBox.shrink();
    final visible = topics.take(maxTopics).toList(growable: false);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final color = isDark ? AppColors.textSecondaryDark : AppColors.brandPrimary;
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: visible
          .map(
            (topic) => Semantics(
              button: true,
              label: '搜索话题 ${topic.name}',
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => SearchResultsScreen(query: topic.name),
                  ),
                ),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                  child: Text(
                    '#${topic.name}',
                    style: TextStyle(
                      color: color,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          )
          .toList(growable: false),
    );
  }
}
