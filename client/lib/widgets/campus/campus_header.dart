import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class CampusHeader extends StatelessWidget {
  final String semester;

  const CampusHeader({super.key, required this.semester});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    // Calculate week number roughly or just hardcode as in example for visual
    // Note: We'll put a placeholder "第18周" or dynamic if available. 
    // Here we can use date logic or just '第18周' for now.
    final now = DateTime.now();
    final dateStr = DateFormat('MM-dd').format(now);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '校园',
                style: TextStyle(
                  fontSize: 27,
                  height: 1.1,
                  fontWeight: FontWeight.w900,
                  color: isDark ? Colors.white : const Color(0xFF20212B),
                ),
              ),
              const SizedBox(height: 7),
              Text(
                semester, // Like "2025-2026 第二学期"
                style: TextStyle(
                  fontSize: 12.5,
                  color: isDark ? Colors.white54 : Colors.black54,
                ),
              ),
            ],
          ),
        ),
        // Right side info pill
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: isDark ? Colors.white.withValues(alpha: 0.1) : Colors.black.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            children: [
              Text(
                '第18周', // Mock value, actual can be passed later if available
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: isDark ? Colors.white70 : Colors.black87,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                dateStr,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.white54 : Colors.black54,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
