import 'package:flutter/material.dart';

import '../../models/poll.dart';
import '../../theme/app_colors.dart';
import 'poll_result_bar.dart';

class PollOptionTile extends StatelessWidget {
  final PollOption option;
  final bool selected;
  final bool multiple;
  final bool enabled;
  final bool showResult;
  final VoidCallback? onTap;

  const PollOptionTile({
    super.key,
    required this.option,
    required this.selected,
    required this.multiple,
    required this.enabled,
    required this.showResult,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final ratio = option.ratio ?? 0;
    return Semantics(
      button: enabled,
      selected: selected,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(8),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          constraints: const BoxConstraints(minHeight: 44),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: selected
                ? accent.withValues(alpha: isDark ? 0.18 : 0.07)
                : (isDark ? AppColors.surfaceMutedDark : AppColors.surfaceMutedLight),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected
                  ? accent.withValues(alpha: 0.55)
                  : (isDark ? AppColors.borderNormalDark : AppColors.borderNormalLight),
            ),
          ),
          child: Column(
            children: [
              Row(
                children: [
                  Icon(
                    selected
                        ? (multiple
                            ? Icons.check_box
                            : Icons.radio_button_checked)
                        : (multiple
                            ? Icons.check_box_outline_blank
                            : Icons.radio_button_off),
                    size: 20,
                    color: selected ? accent : Theme.of(context).hintColor,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      option.text,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13.5, height: 1.25),
                    ),
                  ),
                  if (showResult) ...[
                    const SizedBox(width: 8),
                    Text(
                      '${(ratio * 100).round()}%',
                      style: TextStyle(
                        color: accent,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ],
              ),
              if (showResult) ...[
                const SizedBox(height: 6),
                PollResultBar(ratio: ratio, color: accent),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
