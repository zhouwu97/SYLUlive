import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../../theme/app_radius.dart';

class AiModeSwitch extends StatelessWidget {
  final bool isPersonalMode;
  final ValueChanged<bool> onModeChanged;

  const AiModeSwitch({
    super.key,
    required this.isPersonalMode,
    required this.onModeChanged,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Container(
        height: 48,
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color:
              isDark ? AppColors.brandSurfaceDark : AppColors.brandSurfaceLight,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(
            color: isDark
                ? AppColors.borderNormalDark
                : AppColors.borderNormalLight,
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: _ModeButton(
                icon: Icons.auto_awesome_outlined,
                label: '校园 Agent',
                isSelected: !isPersonalMode,
                onTap: () => onModeChanged(false),
              ),
            ),
            Expanded(
              child: _ModeButton(
                icon: Icons.person_outline_rounded,
                label: '个人助手',
                isSelected: isPersonalMode,
                onTap: () => onModeChanged(true),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModeButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _ModeButton({
    required this.icon,
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: isSelected,
      label: label,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadius.sm),
          child: Container(
            constraints: const BoxConstraints(minHeight: 44),
            decoration: BoxDecoration(
              color: isSelected ? colors.surface : Colors.transparent,
              borderRadius: BorderRadius.circular(AppRadius.sm),
              boxShadow: isSelected
                  ? [
                      BoxShadow(
                        color: colors.shadow.withValues(alpha: 0.08),
                        blurRadius: 4,
                        offset: const Offset(0, 2),
                      ),
                    ]
                  : null,
            ),
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    icon,
                    size: 16,
                    color:
                        isSelected ? colors.primary : colors.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 14,
                      color:
                          isSelected ? colors.primary : colors.onSurfaceVariant,
                      fontWeight:
                          isSelected ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
