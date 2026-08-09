import 'package:flutter/material.dart';
import '../../theme/app_motion.dart';
import '../../theme/app_radius.dart';
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

class CampusServiceCard extends StatefulWidget {
  final CampusServiceItem service;
  final bool isDark;

  const CampusServiceCard({
    super.key,
    required this.service,
    required this.isDark,
  });

  @override
  State<CampusServiceCard> createState() => _CampusServiceCardState();
}

class _CampusServiceCardState extends State<CampusServiceCard> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final service = widget.service;
    final isDark = widget.isDark;

    final content = Container(
      height: 86,
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          AnimatedContainer(
            duration: reduceMotion ? Duration.zero : AppMotion.micro,
            curve: AppMotion.standard,
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: service.color.withValues(alpha: _pressed ? 0.2 : 0.12),
              borderRadius: BorderRadius.circular(AppRadius.md),
              border: Border.all(
                color: service.color.withValues(
                  alpha: _pressed ? 0.24 : 0.0,
                ),
              ),
              boxShadow: _pressed
                  ? [
                      BoxShadow(
                        color: service.color.withValues(alpha: 0.14),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ]
                  : null,
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
    );

    final interactive = Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.md),
        onTap: service.onTap,
        onHighlightChanged: (highlighted) {
          if (mounted) setState(() => _pressed = highlighted);
        },
        child: content,
      ),
    );

    if (reduceMotion) return interactive;

    return AnimatedScale(
      scale: _pressed ? 0.96 : 1.0,
      duration: AppMotion.micro,
      curve: AppMotion.standard,
      child: interactive,
    );
  }
}
