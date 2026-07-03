import 'package:flutter/material.dart';

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
      color: isDark ? const Color(0xFF1B1E28) : Colors.white,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: service.onTap,
        borderRadius: BorderRadius.circular(15),
        child: Container(
          height: 76,
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(15),
            border: Border.all(
              color: isDark ? Colors.white10 : const Color(0xFFF0F1F5),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: service.color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(11),
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
                    fontSize: 11.2,
                    height: 1.0,
                    fontWeight: FontWeight.w700,
                    color: isDark ? Colors.white : const Color(0xFF1F2430),
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
