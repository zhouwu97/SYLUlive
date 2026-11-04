import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import 'app_card.dart';

/// 查询进行中沿用二课页面的卡片尺寸和材质，不另画一块实色底面。
class ErkeQueryProgress extends StatelessWidget {
  const ErkeQueryProgress({
    super.key,
    required this.message,
    required this.decoration,
  });

  final String message;
  final BoxDecoration decoration;

  @override
  Widget build(BuildContext context) => AppCardSurface(
        key: const ValueKey('erke-query-progress-surface'),
        width: double.infinity,
        padding: const EdgeInsets.all(20),
        decoration: decoration,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('查询进度',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            Row(
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: AppColors.brandPrimary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(message,
                      style: Theme.of(context).textTheme.bodyMedium),
                ),
              ],
            ),
          ],
        ),
      );
}
