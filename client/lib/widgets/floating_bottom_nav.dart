import 'package:flutter/material.dart';
import '../theme/app_theme_tokens.dart';
import 'liquid_bottom_nav.dart';
import 'navigation_dock_layout.dart';
import '../features/theme_pack/theme_navigation_images.dart';

/// Ordinary floating navigation: no scene capture, shader, or liquid springs.
class FloatingBottomNav extends StatelessWidget {
  const FloatingBottomNav(
      {super.key,
      required this.currentIndex,
      required this.onTap,
      this.badges = const {},
      this.axis = Axis.horizontal,
      this.docked = false,
      this.themeImages = const {},
      this.originalIcons = false});
  final int currentIndex;
  final ValueChanged<int> onTap;
  final Map<int, bool> badges;
  final Axis axis;
  final bool docked;
  final ThemeNavigationImages themeImages;
  final bool originalIcons;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    return NavigationDockLayout(
        axis: axis,
        docked: docked,
        child: Material(
          color: tokens.navBackground.withValues(alpha: 1),
          elevation: 3,
          borderRadius: BorderRadius.circular(docked ? 0 : 32),
          clipBehavior: Clip.antiAlias,
          child: Flex(
              direction: axis,
              children: List.generate(5, (i) {
                final selected = currentIndex == i;
                final images = themeImages[i];
                final artworkOnly = originalIcons && images != null;
                final iconSize =
                    artworkOnly ? originalThemeNavigationIconSize : 24.0;
                final color =
                    selected ? tokens.navSelected : tokens.navUnselected;
                return Expanded(
                    child: Semantics(
                  button: true,
                  selected: selected,
                  label:
                      '${LiquidBottomNav.labels[i]}${badges[i] == true ? '，有新消息' : ''}',
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Ink(
                      decoration: ShapeDecoration(
                        color: selected
                            ? color.withValues(alpha: .10)
                            : Colors.transparent,
                        shape: const StadiumBorder(),
                      ),
                      child: InkWell(
                        key: ValueKey('bottom-nav-item-$i'),
                        onTap: () => onTap(i),
                        customBorder: const StadiumBorder(),
                        splashFactory: NoSplash.splashFactory,
                        overlayColor: WidgetStateProperty.resolveWith((states) {
                          if (states.contains(WidgetState.pressed)) {
                            return color.withValues(alpha: .12);
                          }
                          if (states.contains(WidgetState.focused) ||
                              states.contains(WidgetState.hovered)) {
                            return color.withValues(alpha: .06);
                          }
                          return Colors.transparent;
                        }),
                        child: ExcludeSemantics(
                          child: Center(
                              child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                Badge(
                                    isLabelVisible: badges[i] == true,
                                    child: images == null
                                        ? Icon(LiquidBottomNav.icons[i],
                                            color: color, size: iconSize)
                                        : Image(
                                            image:
                                                selected ? images.$2 : images.$1,
                                            width: iconSize,
                                            height: iconSize,
                                            fit: BoxFit.contain,
                                            color: originalIcons ? null : color,
                                            colorBlendMode: BlendMode.srcIn,
                                            errorBuilder: (_, __, ___) => Icon(
                                                Icons.broken_image_outlined,
                                                color: color,
                                                size: iconSize))),
                                if (!artworkOnly) ...[
                                  const SizedBox(height: 3),
                                  Text(LiquidBottomNav.labels[i],
                                      maxLines: 1,
                                      style: TextStyle(
                                          fontSize: 11, color: color)),
                                ],
                              ])),
                        ),
                      ),
                    ),
                  ),
                ));
              })),
        ));
  }
}
