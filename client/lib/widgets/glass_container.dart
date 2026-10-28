import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/theme_provider.dart';
import '../theme/app_colors.dart';
import 'app_card.dart';

export 'frosted_glass.dart';

class GlassContainer extends StatelessWidget {
  final Widget child;
  final double? width;
  final double? height;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final double borderRadius;
  final Color? backgroundColor;
  final double blur;

  /// 保留旧调用兼容；卡片透明度统一由 ThemeProvider.componentOpacity 控制。
  final double opacity;
  final double borderWidth;
  final Color? borderColor;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final List<Color>? gradientColors;

  /// 保留旧调用兼容；统一材质不再叠加白色高光。
  final bool showHighlight;

  const GlassContainer({
    super.key,
    required this.child,
    this.width,
    this.height,
    this.padding,
    this.margin,
    this.borderRadius = 12,
    this.backgroundColor,
    this.blur = 10,
    this.opacity = 0.2,
    this.borderWidth = 0.5,
    this.borderColor,
    this.onTap,
    this.onLongPress,
    this.gradientColors,
    this.showHighlight = true,
  });

  @override
  Widget build(BuildContext context) {
    final themeProvider = context.watch<ThemeProvider>();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final useFrostedGlass = themeProvider.frostedGlass && blur > 0;
    final solidSurface = isDark
        ? AppColors.surfaceSecondaryDark
        : AppColors.surfaceSecondaryLight;
    final background = backgroundColor ?? solidSurface;
    final interactive = onTap != null || onLongPress != null;
    // 只绘制一次材质；旧实现把渐变放在模糊层前并叠加白色高光，
    // 导致不透明度失真、白边，以及不同卡片之间的材质差异。
    final content = AppCardSurface(
      width: width,
      height: height,
      margin: margin,
      padding: interactive ? null : padding,
      blur: blur,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: gradientColors == null
            ? (useFrostedGlass
                ? background
                : Color.alphaBlend(background, solidSurface))
            : null,
        gradient: gradientColors == null
            ? null
            : LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: useFrostedGlass
                    ? gradientColors!
                    : gradientColors!
                        .map((color) => Color.alphaBlend(color, solidSurface))
                        .toList(growable: false),
              ),
        borderRadius: BorderRadius.circular(borderRadius),
        border: useFrostedGlass
            ? null
            : Border.all(
                color: borderColor ??
                    (isDark
                        ? AppColors.borderNormalDark
                        : AppColors.borderNormalLight),
                width: borderWidth,
              ),
        boxShadow: useFrostedGlass
            ? null
            : [
                BoxShadow(
                  color: (isDark ? Colors.black : Colors.grey)
                      .withValues(alpha: 0.15),
                  blurRadius: blur * 2,
                  offset: const Offset(0, 2),
                )
              ],
      ),
      child: interactive
          ? Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: onTap,
                onLongPress: onLongPress,
                borderRadius: BorderRadius.circular(borderRadius),
                child: Padding(
                  padding: padding ?? EdgeInsets.zero,
                  child: child,
                ),
              ),
            )
          : child,
    );
    return content;
  }
}

class PremiumCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final VoidCallback? onTap;
  final double borderRadius;
  final List<Color>? gradientColors;

  const PremiumCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.margin = const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    this.onTap,
    this.borderRadius = 16,
    this.gradientColors,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colors = gradientColors ??
        (isDark
            ? [Colors.grey[800]!, Colors.grey[900]!]
            : [Colors.white, Colors.grey[50]!]);

    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: AppCardSurface(
        margin: margin,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: colors,
          ),
          boxShadow: [
            BoxShadow(
              color: (isDark ? Colors.black : Colors.grey).withValues(
                alpha: 0.1,
              ),
              blurRadius: 20,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(borderRadius),
            child: Padding(padding: padding!, child: child),
          ),
        ),
      ),
    );
  }
}

class PremiumIconButton extends StatelessWidget {
  final IconData icon;
  final Color? backgroundColor;
  final Color? iconColor;
  final VoidCallback? onTap;
  final double size;

  const PremiumIconButton({
    super.key,
    required this.icon,
    this.backgroundColor,
    this.iconColor,
    this.onTap,
    this.size = 48,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = backgroundColor ??
        (isDark
            ? Colors.grey[800]!
            : Theme.of(context).primaryColor.withValues(alpha: 0.1));
    final icColor =
        iconColor ?? (isDark ? Colors.white : Theme.of(context).primaryColor);

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(size / 3),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(size / 3),
          child: Icon(icon, color: icColor, size: size * 0.5),
        ),
      ),
    );
  }
}

class GradientButton extends StatelessWidget {
  final String text;
  final VoidCallback? onPressed;
  final List<Color>? gradientColors;
  final double height;
  final double borderRadius;
  final bool isLoading;

  const GradientButton({
    super.key,
    required this.text,
    this.onPressed,
    this.gradientColors,
    this.height = 48,
    this.borderRadius = 12,
    this.isLoading = false,
  });

  @override
  Widget build(BuildContext context) {
    final colors = gradientColors ??
        [
          Theme.of(context).primaryColor,
          Theme.of(context).primaryColor.withValues(alpha: 0.7),
        ];

    return Container(
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(borderRadius),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: onPressed != null ? colors : [Colors.grey, Colors.grey],
        ),
        boxShadow: onPressed != null
            ? [
                BoxShadow(
                  color: colors.first.withValues(alpha: 0.3),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ]
            : null,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: isLoading ? null : onPressed,
          borderRadius: BorderRadius.circular(borderRadius),
          child: Center(
            child: isLoading
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation(Colors.white),
                    ),
                  )
                : Text(
                    text,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: 16,
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}
