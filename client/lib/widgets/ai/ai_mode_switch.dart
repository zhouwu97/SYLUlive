import 'package:flutter/material.dart';
import '../campus/campus_theme.dart';

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
    final colors = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0),
      child: Container(
        height: 42,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: isDark
              ? colors.surfaceContainerHighest
              : CampusTheme.primaryLight,
          borderRadius: BorderRadius.circular(21),
          border: Border.all(color: colors.outlineVariant, width: 1),
        ),
        child: Row(
          children: [
            Expanded(
              child: _ModeButton(
                icon: Icons.public_outlined,
                label: '校园问答',
                isSelected: !isPersonalMode,
                onTap: () => onModeChanged(false),
              ),
            ),
            Expanded(
              child: _ModeButton(
                icon: Icons.person_outline,
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
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        decoration: BoxDecoration(
          color: isSelected ? colors.surface : Colors.transparent,
          borderRadius: BorderRadius.circular(18),
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
                color: isSelected ? colors.primary : colors.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 14,
                  color: isSelected ? colors.primary : colors.onSurfaceVariant,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
