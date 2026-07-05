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
    return Material(
      color: isDark ? CampusTheme.darkCard : Colors.white,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: service.onTap,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          height: 78,
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: isDark ? Colors.white.withValues(alpha: 0.04) : CampusTheme.softBorder.withValues(alpha: 0.5),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: service.color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Icon(
                  service.icon,
                  color: service.color,
                  size: 18,
                ),
              ),
              const SizedBox(height: 3),
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
      ),
    );
  }
}
