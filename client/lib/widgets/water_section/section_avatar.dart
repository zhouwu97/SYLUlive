import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../config/api_constants.dart';
import '../../models/water_section.dart';

class SectionAvatar extends StatelessWidget {
  final WaterSection section;
  final double size;
  final double radius;
  final Color? accentColor;
  final bool showBorder;
  final Color? borderColor;
  final double borderWidth;
  final bool isDark;

  const SectionAvatar({
    super.key,
    required this.section,
    required this.size,
    this.radius = 12,
    this.accentColor,
    this.showBorder = false,
    this.borderColor,
    this.borderWidth = 1.0,
    this.isDark = false,
  });

  @override
  Widget build(BuildContext context) {
    Color effectiveAccentColor = accentColor ?? Theme.of(context).primaryColor;
    if (accentColor == null &&
        section.colorHex.isNotEmpty &&
        section.colorHex != '#') {
      try {
        effectiveAccentColor = Color(
            int.parse(section.colorHex.substring(1), radix: 16) + 0xFF000000);
      } catch (_) {}
    }

    final fallbackIcon =
        iconKeyToIconData(section.iconKey, fallbackSlug: section.slug);
    final backgroundColor =
        effectiveAccentColor.withValues(alpha: isDark ? 0.16 : 0.10);
    final iconColor = effectiveAccentColor;

    final border = showBorder
        ? Border.all(
            color: borderColor ??
                (isDark
                    ? Colors.white.withValues(alpha: 0.12)
                    : Colors.black.withValues(alpha: 0.08)),
            width: borderWidth,
          )
        : null;

    Widget avatarContent;

    if (section.avatarUrl.isNotEmpty) {
      avatarContent = CachedNetworkImage(
        imageUrl: ApiConstants.fullUrl(section.avatarUrl),
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorWidget: (context, url, error) =>
            _buildFallback(fallbackIcon, iconColor, backgroundColor),
        placeholder: (context, url) => Container(color: backgroundColor),
      );
    } else {
      avatarContent = _buildFallback(fallbackIcon, iconColor, backgroundColor);
    }

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        border: border,
        color: backgroundColor, // 保证图片加载或透明图时底色正常
      ),
      clipBehavior: Clip.antiAlias,
      child: avatarContent,
    );
  }

  Widget _buildFallback(IconData icon, Color iconColor, Color backgroundColor) {
    return Container(
      width: size,
      height: size,
      color: backgroundColor,
      child: Icon(
        icon,
        size: size * 0.55,
        color: iconColor,
      ),
    );
  }
}
