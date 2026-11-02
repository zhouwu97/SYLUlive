import 'package:flutter/material.dart';

import '../../theme/app_radius.dart';
import '../../theme/app_colors.dart';

/// 玻璃特效设置共用的预览画布；实际特效仍由各自的场景组件绘制。
class SettingsEffectPreview extends StatelessWidget {
  const SettingsEffectPreview({super.key, this.clipKey, required this.child});

  final Key? clipKey;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // 标题与对照标签随字号增高，两类预览同步留出空间。
    final extraHeight = (MediaQuery.textScalerOf(context).scale(48) - 48)
        .clamp(0.0, double.infinity);
    return ClipRRect(
      key: clipKey,
      borderRadius: BorderRadius.circular(AppRadius.sheet),
      child: SizedBox(height: 220 + extraHeight, child: child),
    );
  }
}

class SettingsEffectPreviewBackground extends StatelessWidget {
  const SettingsEffectPreviewBackground({super.key, required this.title});

  final String title;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xffb1d5e2), Color(0xffecd0d7), Color(0xffdce9fa)],
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Align(
            alignment: Alignment.topLeft,
            child: Text(title,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: AppColors.textPrimaryLight,
                    )),
          ),
        ),
      );
}
