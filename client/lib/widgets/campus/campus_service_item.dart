import '../../theme/app_theme_tokens.dart';
import 'package:flutter/material.dart';

import '../../theme/app_theme_style.dart';
import '../../theme/app_motion.dart';
import '../../theme/app_palette.dart';

class CampusServiceItem {
  final String title;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  /// 主题包 serviceIcons 中对应的键；主题提供图片时替换 [icon]。
  final String? themeKey;

  const CampusServiceItem({
    required this.title,
    required this.icon,
    this.themeKey,
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
    final style = AppThemeStyle.of(context);
    final serviceColor = style.identity(service.color);
    final themedIcon = style.serviceIcon(context, service.themeKey);

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
              color: themedIcon != null
                  ? Colors.transparent
                  : serviceColor.withValues(alpha: _pressed ? 0.2 : 0.12),
              borderRadius: BorderRadius.circular(AppShape.of(context).md),
              border: Border.all(
                color: serviceColor.withValues(
                  alpha: _pressed ? 0.24 : 0.0,
                ),
              ),
              boxShadow: _pressed
                  ? [
                      BoxShadow(
                        color: serviceColor.withValues(alpha: 0.14),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ]
                  : null,
            ),
            child: themedIcon == null
                ? Icon(
                    service.icon,
                    color: serviceColor,
                    size: 20,
                  )
                : AnimatedScale(
                    scale: _pressed ? 0.92 : 1,
                    duration: reduceMotion ? Duration.zero : AppMotion.micro,
                    child: themedIcon,
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
                color: AppThemeTokens.of(context).textPrimary,
              ),
            ),
          ),
        ],
      ),
    );

    final interactive = Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppShape.of(context).md),
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
