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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0),
      child: Container(
        height: 42,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: const Color(0xFFE8F5F2), // primarySoft
          borderRadius: BorderRadius.circular(21),
          border: Border.all(color: const Color(0xFFE3E8E5), width: 1),
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
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        decoration: BoxDecoration(
          color: isSelected ? Colors.white : Colors.transparent,
          borderRadius: BorderRadius.circular(18),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.05),
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
                color: isSelected ? CampusTheme.primary : const Color(0xFF7B8388),
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 14,
                  color: isSelected ? CampusTheme.primary : const Color(0xFF7B8388),
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
