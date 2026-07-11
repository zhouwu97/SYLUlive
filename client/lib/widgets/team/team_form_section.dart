import 'package:flutter/material.dart';
import 'team_ui_tokens.dart';

class TeamFormSection extends StatelessWidget {
  final String title;
  final List<Widget> children;

  const TeamFormSection({
    super.key,
    required this.title,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text(
            title,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: TeamUiTokens.title(isDark),
            ),
          ),
        ),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: TeamUiTokens.cardBg(isDark),
            borderRadius: BorderRadius.circular(TeamUiTokens.cardRadius),
            border: Border.all(color: TeamUiTokens.border(isDark)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: children,
          ),
        ),
      ],
    );
  }
}
