import 'package:flutter/material.dart';

import '../campus/campus_theme.dart';

class AiTypingStatus extends StatelessWidget {
  final String status;
  const AiTypingStatus({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: CampusTheme.softBorder),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: CampusTheme.primary,
              ),
            ),
            const SizedBox(width: 9),
            Text(
              status.isEmpty ? '正在查找可靠信息…' : status,
              style:
                  const TextStyle(color: CampusTheme.subText, fontSize: 12.5),
            ),
          ],
        ),
      ),
    );
  }
}
