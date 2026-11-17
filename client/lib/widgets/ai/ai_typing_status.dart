import 'package:shenliyuan/widgets/app_card.dart';
import 'package:flutter/material.dart';
import '../../theme/app_theme_tokens.dart';

class AiTypingStatus extends StatelessWidget {
  final String status;
  const AiTypingStatus({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: AppCardSurface(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: AppThemeTokens.of(context).card,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AppThemeTokens.of(context).cardBorder),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AppThemeTokens.of(context).primary,
              ),
            ),
            const SizedBox(width: 9),
            Text(
              status.isEmpty ? '正在查找可靠信息…' : status,
              style: TextStyle(
                  color: AppThemeTokens.of(context).textSecondary,
                  fontSize: 12.5),
            ),
          ],
        ),
      ),
    );
  }
}
