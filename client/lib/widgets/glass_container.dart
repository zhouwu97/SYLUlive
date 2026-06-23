import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/theme_provider.dart';

class GlassContainer extends StatelessWidget {
  final Widget child;
  final double? width;
  final double? height;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final double borderRadius;
  final Color? backgroundColor;
  final double blur;
  final double opacity;
  final double borderWidth;
  final Color? borderColor;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final List<Color>? gradientColors;
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
    final useLiquidGlass = themeProvider.liquidGlass && blur > 0;
    final compOpacity = themeProvider.componentOpacity;

    final defaultBorderColor = isDark
        ? Colors.white.withValues(alpha: 0.15)
        : Colors.white.withValues(alpha: 0.6);
    final defaultBgColor = isDark
        ? Colors.white.withValues(alpha: compOpacity * 0.12)
        : Colors.white.withValues(alpha: compOpacity * 0.55);

    Widget content = Container(
      width: width,
      height: height,
      margin: margin,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: Stack(
          children: [
            if (gradientColors != null)
              Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(borderRadius),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: gradientColors!,
                  ),
                ),
              ),
            if (useLiquidGlass)
              BackdropFilter(
                filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
                child: Container(
                  decoration: BoxDecoration(
                    color: gradientColors == null
                        ? (backgroundColor ?? defaultBgColor)
                        : (gradientColors!.first).withValues(alpha: 0.35),
                    borderRadius: BorderRadius.circular(borderRadius),
                    border: Border.all(
                      color: borderColor ?? defaultBorderColor,
                      width: borderWidth,
                    ),
                  ),
                  padding: padding,
                  child: child,
                ),
              )
            else
              Container(
                decoration: BoxDecoration(
                  color: gradientColors != null
                      ? gradientColors!.first.withValues(alpha: 0.5)
                      : (backgroundColor ?? defaultBgColor),
                  borderRadius: BorderRadius.circular(borderRadius),
                  border: Border.all(
                    color: borderColor ?? defaultBorderColor,
                    width: borderWidth,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: (isDark ? Colors.black : Colors.grey)
                          .withValues(alpha: 0.15),
                      blurRadius: blur * 2,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                padding: padding,
                child: child,
              ),
            if (useLiquidGlass && showHighlight)
              Positioned(
                top: 0,
                left: borderRadius * 0.5,
                right: borderRadius * 0.5,
                height: 0.5,
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(borderRadius),
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.white.withValues(alpha: 0.4),
                        Colors.white.withValues(alpha: 0.0),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );

    if (onTap != null || onLongPress != null) {
      return Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          borderRadius: BorderRadius.circular(borderRadius),
          child: content,
        ),
      );
    }

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
      child: Container(
        margin: margin,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: colors,
          ),
          boxShadow: [
            BoxShadow(
              color:
                  (isDark ? Colors.black : Colors.grey).withValues(alpha: 0.1),
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
            child: Padding(
              padding: padding!,
              child: child,
            ),
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
          Theme.of(context).primaryColor.withValues(alpha: 0.7)
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
