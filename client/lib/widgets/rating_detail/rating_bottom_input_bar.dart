import 'package:flutter/material.dart';

class RatingBottomInputBar extends StatelessWidget {
  final String hintText;
  final VoidCallback onTap;

  const RatingBottomInputBar({
    super.key,
    required this.hintText,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    return Container(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 10,
        bottom: 10 + MediaQuery.of(context).padding.bottom,
      ),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1B1E28) : Colors.white,
        border: Border(
          top: BorderSide(
            color: isDark ? Colors.white10 : Colors.black.withValues(alpha: 0.05),
          ),
        ),
      ),
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: isDark ? Colors.white10 : const Color(0xFFF4F6FB),
            borderRadius: BorderRadius.circular(19),
          ),
          child: Row(
            children: [
              Icon(
                Icons.edit_rounded,
                size: 16,
                color: isDark ? Colors.white54 : Colors.black45,
              ),
              const SizedBox(width: 8),
              Text(
                hintText,
                style: TextStyle(
                  fontSize: 14,
                  color: isDark ? Colors.white54 : Colors.black45,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
