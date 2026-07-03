import 'package:flutter/material.dart';

enum RatingPolicyType {
  info,
  warning,
}

class RatingPolicyTip extends StatelessWidget {
  final String text;
  final RatingPolicyType type;

  const RatingPolicyTip({
    super.key,
    required this.text,
    this.type = RatingPolicyType.info,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    final bool isWarning = type == RatingPolicyType.warning;
    final Color bgColor = isWarning
        ? Colors.orange.withValues(alpha: isDark ? 0.14 : 0.08)
        : (isDark ? const Color(0xFF202636) : const Color(0xFFF7F8FC));
    final Border? border = isWarning
        ? Border.all(color: Colors.orange.withValues(alpha: isDark ? 0.28 : 0.18))
        : null;
    final IconData iconData = isWarning ? Icons.warning_amber_rounded : Icons.info_outline_rounded;
    final Color iconColor = isWarning ? Colors.orange[700]! : (isDark ? Colors.grey.shade300 : Colors.grey.shade600);
    final Color textColor = isDark ? Colors.grey.shade300 : Colors.grey.shade600;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(10),
        border: border,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            iconData,
            size: 14,
            color: iconColor,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 12,
                height: 1.35,
                color: textColor,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
