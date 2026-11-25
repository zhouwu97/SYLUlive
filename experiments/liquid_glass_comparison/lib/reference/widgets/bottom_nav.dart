import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_motion.dart';
import '../theme/app_text_styles.dart';
import 'liquid_bottom_nav.dart' as liquid;

/// SYLUlive five-item navigation with normal, floating and liquid styles.
enum BottomNavStyle { liquidGlass, floating, normal }

class BottomNav extends StatelessWidget {
  const BottomNav({
    super.key,
    required this.currentIndex,
    required this.onTap,
    this.style = BottomNavStyle.floating,
    this.badges = const {},
    this.compareGlass = false,
    this.glassBlur = 6,
    this.glassTint,
  }) : assert(currentIndex >= 0 && currentIndex < 5);

  final int currentIndex;
  final ValueChanged<int> onTap;
  final BottomNavStyle style;
  final Map<int, bool> badges;
  final bool compareGlass;
  final double glassBlur;
  final double? glassTint;

  static const labels = ['首页', '集市', '课表', '校园', '我'];
  static const icons = [
    Icons.home_rounded,
    Icons.storefront_rounded,
    Icons.calendar_month_rounded,
    Icons.apartment_rounded,
    Icons.person_rounded,
  ];

  @override
  Widget build(BuildContext context) {
    if (style == BottomNavStyle.liquidGlass) {
      return _LiquidNavAdapter(
        currentIndex: currentIndex,
        onTap: onTap,
        badges: badges,
        compare: compareGlass,
        blur: glassBlur,
        tint: glassTint,
      );
    }
    final dark = Theme.of(context).brightness == Brightness.dark;
    final floating = style == BottomNavStyle.floating;
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    final surface = dark
        ? AppColors.surfaceSecondaryDark
        : AppColors.surfaceSecondaryLight;
    final content = LayoutBuilder(
      builder: (context, constraints) {
        final itemWidth = constraints.maxWidth / labels.length;
        return SizedBox(
          height: floating ? 64 : 54,
          child: Stack(
            alignment: Alignment.center,
            children: [
              AnimatedPositioned(
                duration: reducedMotion ? Duration.zero : AppMotion.tab,
                curve: AppMotion.movement,
                left:
                    itemWidth * currentIndex +
                    (itemWidth - (floating ? 56 : 48)) / 2,
                child: Container(
                  key: const ValueKey('bottom-nav-selection'),
                  width: floating ? 56 : 48,
                  height: floating ? 48 : 44,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: floating
                          ? [
                              AppColors.brandPrimary.withValues(
                                alpha: dark ? .28 : .05,
                              ),
                              AppColors.brandPrimary.withValues(
                                alpha: dark ? .12 : .10,
                              ),
                            ]
                          : [
                              AppColors.brandPrimary.withValues(alpha: .18),
                              AppColors.brandPrimary.withValues(alpha: .07),
                            ],
                    ),
                    borderRadius: BorderRadius.circular(floating ? 24 : 14),
                    border: Border.all(
                      color: AppColors.brandPrimary.withValues(
                        alpha: floating ? (dark ? .30 : .14) : .10,
                      ),
                    ),
                    boxShadow: floating
                        ? null
                        : [
                            BoxShadow(
                              color: AppColors.brandPrimary.withValues(
                                alpha: .12,
                              ),
                              blurRadius: 14,
                              offset: const Offset(0, 5),
                            ),
                          ],
                  ),
                ),
              ),
              Row(
                children: List.generate(labels.length, (index) {
                  final selected = index == currentIndex;
                  final color = selected
                      ? (dark
                            ? const Color(0xFF72D5C6)
                            : AppColors.brandPrimary)
                      : (dark
                            ? AppColors.iconMutedDark
                            : AppColors.iconMutedLight);
                  return Expanded(
                    child: Semantics(
                      label: labels[index],
                      button: true,
                      selected: selected,
                      child: ExcludeSemantics(
                        child: Material(
                          color: Colors.transparent,
                          child: InkWell(
                            key: ValueKey('bottom-nav-item-$index'),
                            onTap: () => onTap(index),
                            child: SizedBox(
                              height: floating ? 64 : 54,
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Stack(
                                    clipBehavior: Clip.none,
                                    children: [
                                      Icon(
                                        icons[index],
                                        color: color,
                                        size: floating ? 24 : 22,
                                      ),
                                      if (badges[index] == true)
                                        Positioned(
                                          top: -1,
                                          right: -3,
                                          child: Container(
                                            width: 8,
                                            height: 8,
                                            decoration: const BoxDecoration(
                                              color: AppColors.danger,
                                              shape: BoxShape.circle,
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    labels[index],
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: floating
                                        ? AppTextStyles.labelMedium.copyWith(
                                            color: color,
                                          )
                                        : TextStyle(
                                            color: color,
                                            fontWeight: FontWeight.w600,
                                            fontSize: 10,
                                          ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ],
          ),
        );
      },
    );

    if (!floating) {
      return Container(
        padding: EdgeInsets.only(
          top: 2,
          bottom: MediaQuery.paddingOf(context).bottom > 0
              ? MediaQuery.paddingOf(context).bottom
              : 2,
        ),
        decoration: BoxDecoration(
          color: surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          border: Border(
            top: BorderSide(
              color: dark
                  ? Colors.white10
                  : Colors.black.withValues(alpha: .06),
              width: .5,
            ),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: dark ? .18 : .06),
              blurRadius: 10,
              offset: const Offset(0, -2),
            ),
          ],
        ),
        child: content,
      );
    }
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: Align(
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Container(
              key: const ValueKey('bottom-nav-floating-dock'),
              decoration: BoxDecoration(
                color: surface,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: dark
                      ? Colors.white.withValues(alpha: .14)
                      : AppColors.borderNormalLight,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: dark ? .24 : .09),
                    blurRadius: 16,
                    offset: const Offset(0, 7),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: content,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LiquidNavAdapter extends StatefulWidget {
  const _LiquidNavAdapter({
    required this.currentIndex,
    required this.onTap,
    required this.badges,
    required this.compare,
    required this.blur,
    this.tint,
  });
  final int currentIndex;
  final ValueChanged<int> onTap;
  final Map<int, bool> badges;
  final bool compare;
  final double blur;
  final double? tint;

  @override
  State<_LiquidNavAdapter> createState() => _LiquidNavAdapterState();
}

class _LiquidNavAdapterState extends State<_LiquidNavAdapter> {
  late final ValueNotifier<double> _position = ValueNotifier(
    widget.currentIndex.toDouble(),
  );

  int? _internalTarget;

  void _select(int index) {
    _internalTarget = index;
    widget.onTap(index);
  }

  @override
  void didUpdateWidget(covariant _LiquidNavAdapter oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentIndex != widget.currentIndex) {
      if (_internalTarget != widget.currentIndex) {
        _position.value = widget.currentIndex.toDouble();
      }
      _internalTarget = null;
    }
  }

  @override
  void dispose() {
    _position.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => liquid.BottomNavWrapper(
    currentIndex: widget.currentIndex,
    visualIndexListenable: _position,
    onTap: _select,
    onNavigationCommitted: _select,
    badges: widget.badges,
    compare: widget.compare,
    blur: widget.blur,
    tint: widget.tint,
  );
}
