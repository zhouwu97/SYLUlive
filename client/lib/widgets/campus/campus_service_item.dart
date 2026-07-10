import 'package:flutter/material.dart';
import 'campus_theme.dart';

class CampusServiceItem {
  final String title;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const CampusServiceItem({
    required this.title,
    required this.icon,
    required this.color,
    required this.onTap,
  });
}

class CampusServiceCard extends StatelessWidget {
  final CampusServiceItem service;
  final bool isDark;

  const CampusServiceCard({
    super.key,
    required this.service,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: service.onTap,
      child: Container(
        height: 86,
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: service.color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(
                service.icon,
                color: service.color,
                size: 20,
              ),
            ),
            const SizedBox(height: 6),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                service.title,
                maxLines: 1,
                style: TextStyle(
                  fontSize: 11.5,
                  height: 1.0,
                  fontWeight: FontWeight.w700,
                  color: isDark ? Colors.white : CampusTheme.text,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
