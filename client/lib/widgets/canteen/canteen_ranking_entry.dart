import 'package:flutter/material.dart';

import '../../models/canteen_home.dart';
import '../../theme/app_motion.dart';
import 'canteen_theme.dart';

/// 首页“综合排行”快捷入口。
///
/// 这里解释排序依据，不把榜单数字塞进首页，避免用户误以为它是另一组评分。
class CanteenRankingEntryCard extends StatefulWidget {
  final CanteenRankingEntry entry;
  final VoidCallback onTap;

  const CanteenRankingEntryCard({
    super.key,
    required this.entry,
    required this.onTap,
  });

  @override
  State<CanteenRankingEntryCard> createState() =>
      _CanteenRankingEntryCardState();
}

class _CanteenRankingEntryCardState extends State<CanteenRankingEntryCard> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: widget.onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedScale(
        scale: _pressed ? 0.99 : 1.0,
        duration: AppMotion.micro,
        curve: AppMotion.standard,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: CanteenTheme.surfaceBg(isDark),
            borderRadius: BorderRadius.circular(CanteenTheme.radiusLg),
            border: Border.all(color: CanteenTheme.borderColor(isDark)),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: CanteenTheme.accentSoftColor(isDark),
                  borderRadius: BorderRadius.circular(13),
                ),
                alignment: Alignment.center,
                child: Text(
                  '#1',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w900,
                    color: CanteenTheme.accentStrongColor(isDark),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '综合排行',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: CanteenTheme.textPrimaryColor(isDark),
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '信用加权 + 样本修正',
                      style: TextStyle(
                        fontSize: 12,
                        color: CanteenTheme.textSecondaryColor(isDark),
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: CanteenTheme.textTertiaryColor(isDark),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
