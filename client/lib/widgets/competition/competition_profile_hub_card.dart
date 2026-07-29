import 'package:flutter/material.dart';

import 'competition_ui_tokens.dart';

class CompetitionProfileHubItem {
  final IconData icon;
  final String title;
  final String status;
  final String subtitle;
  final VoidCallback onTap;

  const CompetitionProfileHubItem({
    required this.icon,
    required this.title,
    required this.status,
    required this.subtitle,
    required this.onTap,
  });
}

class CompetitionProfileHubCard extends StatelessWidget {
  final List<CompetitionProfileHubItem> items;

  const CompetitionProfileHubCard({super.key, required this.items});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      decoration: CompetitionUiTokens.cardDecoration(isDark),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (var index = 0; index < items.length; index++) ...[
            _HubRow(item: items[index]),
            if (index != items.length - 1)
              Divider(
                height: 1,
                indent: 52,
                color: CompetitionUiTokens.borderColor(isDark),
              ),
          ],
        ],
      ),
    );
  }
}

class _HubRow extends StatelessWidget {
  final CompetitionProfileHubItem item;

  const _HubRow({required this.item});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return InkWell(
      onTap: item.onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 10, 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              item.icon,
              size: 22,
              color: CompetitionUiTokens.accent(isDark),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          item.title,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: CompetitionUiTokens.titleColor(isDark),
                          ),
                        ),
                      ),
                      Text(
                        item.status,
                        style: TextStyle(
                          fontSize: 12,
                          color: CompetitionUiTokens.accent(isDark),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Icon(
                        Icons.chevron_right_rounded,
                        size: 20,
                        color: CompetitionUiTokens.subColor(isDark),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    item.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: CompetitionUiTokens.subColor(isDark),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
