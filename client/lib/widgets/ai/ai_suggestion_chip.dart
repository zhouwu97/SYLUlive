import 'package:flutter/material.dart';

class AiSuggestionChip extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const AiSuggestionChip({
    super.key,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(11),
      child: Container(
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(11),
          border: Border.all(color: colors.outlineVariant),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            color: colors.onSurface,
          ),
        ),
      ),
    );
  }
}
