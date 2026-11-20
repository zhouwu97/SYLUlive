import 'package:flutter/material.dart';
import '../../theme/app_theme_tokens.dart';

class AiAssistantIntroCard extends StatelessWidget {
  final String title;
  final String subtitle;

  const AiAssistantIntroCard({
    super.key,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            color: AppThemeTokens.of(context).textPrimary,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          subtitle,
          style: TextStyle(
            fontSize: 13,
            color: AppThemeTokens.of(context).textSecondary,
            height: 1.45,
          ),
        ),
      ],
    );
  }
}
