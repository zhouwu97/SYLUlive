import 'package:flutter/material.dart';

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

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0),
      child: Container(
        height: 40,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
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
                colors: colors,
              ),
            ),
            Expanded(
              child: _ModeButton(
                icon: Icons.person_outline,
                label: '个人助手',
                isSelected: isPersonalMode,
                onTap: () => onModeChanged(true),
                colors: colors,
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
  final ColorScheme colors;

  const _ModeButton({
    required this.icon,
    required this.label,
    required this.isSelected,
    required this.onTap,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        decoration: BoxDecoration(
          color: isSelected ? colors.primaryContainer : Colors.transparent,
          borderRadius: BorderRadius.circular(19),
        ),
        child: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 18,
                color: isSelected ? colors.onPrimaryContainer : colors.onSurface,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 14,
                  color: isSelected ? colors.onPrimaryContainer : colors.onSurface,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
