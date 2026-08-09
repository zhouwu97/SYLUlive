import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/theme_provider.dart';
import '../theme/app_colors.dart';

class _NavItemVisualState {
  const _NavItemVisualState({
    required this.color,
    required this.fontWeight,
  });

  final Color color;
  final FontWeight fontWeight;
}

class BottomNavWrapper extends StatelessWidget {
  final int currentIndex;
  final ValueListenable<double> visualIndexListenable;
  final Function(int) onTap;
  final AuthProvider authProvider;
  final Map<int, bool> badges;

  const BottomNavWrapper({
    super.key,
    required this.currentIndex,
    required this.visualIndexListenable,
    required this.onTap,
    required this.authProvider,
    this.badges = const {},
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final themeProvider = context.watch<ThemeProvider>();

    if (themeProvider.floatingNavBar) {
      return _buildFloatingNav(context, isDark);
    }

    return _buildBlurNav(context, isDark);
  }

  // 标准模式：毛玻璃底栏 紧贴底部 + 紧凑
  Widget _buildBlurNav(BuildContext context, bool isDark) {
    final bottomSafe = MediaQuery.of(context).padding.bottom;
    const primaryColor = AppColors.brandPrimary;

    return LayoutBuilder(
      builder: (context, constraints) {
        final itemWidth = constraints.maxWidth / 5;

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(16),
              ),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                child: Container(
                  padding: EdgeInsets.only(
                    top: 2,
                    bottom: bottomSafe > 0 ? bottomSafe : 2,
                  ),
                  decoration: BoxDecoration(
                    color:
                        (isDark ? AppColors.surfaceSecondaryDark : Colors.white)
                            .withValues(alpha: 0.85),
                    border: Border(
                      top: BorderSide(
                        color: isDark
                            ? Colors.white10
                            : Colors.black.withValues(alpha: 0.06),
                        width: 0.5,
                      ),
                    ),
                  ),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      // 只让 indicator 订阅逐帧进度，避免 Home/Scaffold 重建。
                      Positioned.fill(
                        child: ValueListenableBuilder<double>(
                          valueListenable: visualIndexListenable,
                          builder: (context, visualIndex, child) {
                            return Align(
                              alignment: Alignment.centerLeft,
                              child: Transform.translate(
                                offset: Offset(itemWidth * visualIndex, 0),
                                child: SizedBox(
                                  width: itemWidth,
                                  child: Center(
                                    child: Container(
                                      width: 48,
                                      height: 44,
                                      decoration: BoxDecoration(
                                        gradient: LinearGradient(
                                          begin: Alignment.topLeft,
                                          end: Alignment.bottomRight,
                                          colors: [
                                            primaryColor.withValues(
                                                alpha: 0.18),
                                            primaryColor.withValues(
                                                alpha: 0.07),
                                          ],
                                        ),
                                        borderRadius: BorderRadius.circular(14),
                                        border: Border.all(
                                          color: primaryColor.withValues(
                                            alpha: 0.1,
                                          ),
                                        ),
                                        boxShadow: [
                                          BoxShadow(
                                            color: primaryColor.withValues(
                                              alpha: 0.12,
                                            ),
                                            blurRadius: 14,
                                            offset: const Offset(0, 5),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                      ValueListenableBuilder<double>(
                        valueListenable: visualIndexListenable,
                        builder: (context, visualIndex, child) {
                          const icons = [
                            Icons.home_rounded,
                            Icons.storefront_rounded,
                            Icons.calendar_month_rounded,
                            Icons.apartment_rounded,
                            Icons.person_rounded,
                          ];
                          const labels = ['首页', '集市', '课表', '校园', '我'];
                          return Row(
                            mainAxisAlignment: MainAxisAlignment.spaceAround,
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: List.generate(
                              icons.length,
                              (index) => _labeledItem(
                                icons[index],
                                labels[index],
                                index,
                                context,
                                primaryColor,
                                itemWidth,
                                visualIndex,
                                badges[index] == true,
                              ),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  // 悬浮模式：连成一块的弧形 Dock
  Widget _buildFloatingNav(BuildContext context, bool isDark) {
    const primaryColor = AppColors.brandPrimary;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(28),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: Container(
              height: 64,
              decoration: BoxDecoration(
                color: isDark
                    ? const Color(0xFF1E2226).withValues(alpha: 0.86)
                    : Colors.white.withValues(alpha: 0.92),
                borderRadius: BorderRadius.circular(28),
                border: Border.all(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.08)
                      : AppColors.borderNormalLight,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.08),
                    blurRadius: 18,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final itemWidth = constraints.maxWidth / 5;
                  return Stack(
                    alignment: Alignment.center,
                    children: [
                      Positioned.fill(
                        child: ValueListenableBuilder<double>(
                          valueListenable: visualIndexListenable,
                          builder: (context, visualIndex, child) {
                            return Align(
                              alignment: Alignment.centerLeft,
                              child: Transform.translate(
                                offset: Offset(itemWidth * visualIndex, 0),
                                child: SizedBox(
                                  width: itemWidth,
                                  child: Center(
                                    child: Container(
                                      width: 56,
                                      height: 40,
                                      decoration: BoxDecoration(
                                        gradient: LinearGradient(
                                          begin: Alignment.topLeft,
                                          end: Alignment.bottomRight,
                                          colors: isDark
                                              ? [
                                                  primaryColor.withValues(
                                                    alpha: 0.24,
                                                  ),
                                                  primaryColor.withValues(
                                                    alpha: 0.1,
                                                  ),
                                                ]
                                              : [
                                                  const Color(0xFFF3FBF8),
                                                  const Color(0xFFE5F5F0),
                                                ],
                                        ),
                                        borderRadius: BorderRadius.circular(18),
                                        border: Border.all(
                                          color: primaryColor.withValues(
                                            alpha: isDark ? 0.26 : 0.12,
                                          ),
                                        ),
                                        boxShadow: [
                                          BoxShadow(
                                            color: primaryColor.withValues(
                                              alpha: isDark ? 0.18 : 0.1,
                                            ),
                                            blurRadius: 16,
                                            offset: const Offset(0, 5),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                      ValueListenableBuilder<double>(
                        valueListenable: visualIndexListenable,
                        builder: (context, visualIndex, child) {
                          const icons = [
                            Icons.home_rounded,
                            Icons.storefront_rounded,
                            Icons.calendar_month_rounded,
                            Icons.apartment_rounded,
                            Icons.person_rounded,
                          ];
                          return Row(
                            mainAxisAlignment: MainAxisAlignment.spaceAround,
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: List.generate(
                              icons.length,
                              (index) => _iconOnly(
                                icons[index],
                                index,
                                context,
                                primaryColor,
                                itemWidth,
                                visualIndex,
                                badges[index] == true,
                              ),
                            ),
                          );
                        },
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  // 标准模式 Item（图标+文字）
  Widget _labeledItem(
    IconData icon,
    String label,
    int index,
    BuildContext context,
    Color primaryColor,
    double width,
    double visualIndex,
    bool showBadge,
  ) {
    final visualState = _visualStateFor(
      context: context,
      index: index,
      primaryColor: primaryColor,
      visualIndex: visualIndex,
    );
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onTap(index),
      child: SizedBox(
        width: width,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Icon(icon, color: visualState.color, size: 22),
                  if (showBadge)
                    Positioned(
                      top: -2,
                      right: -4,
                      child: Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(
                          color: Colors.red,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                label,
                style: TextStyle(
                  color: visualState.color,
                  fontWeight: visualState.fontWeight,
                  fontSize: 10,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // 悬浮模式 Item（纯图标）
  Widget _iconOnly(
    IconData icon,
    int index,
    BuildContext context,
    Color primaryColor,
    double width,
    double visualIndex,
    bool showBadge,
  ) {
    final visualState = _visualStateFor(
      context: context,
      index: index,
      primaryColor: primaryColor,
      visualIndex: visualIndex,
    );

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onTap(index),
      child: SizedBox(
        width: width,
        height: 44,
        child: Center(
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Icon(icon, color: visualState.color, size: 24),
              if (showBadge)
                Positioned(
                  top: 0,
                  right: -2,
                  child: Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                      color: Colors.red,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  _NavItemVisualState _visualStateFor({
    required BuildContext context,
    required int index,
    required Color primaryColor,
    required double visualIndex,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final activeT = (1 - (visualIndex - index).abs()).clamp(0.0, 1.0);
    final softenedT = Curves.easeOutCubic.transform(activeT);
    final inactiveColor = isDark ? Colors.white54 : Colors.grey;

    return _NavItemVisualState(
      color: Color.lerp(inactiveColor, AppColors.brandPrimary, softenedT)!,
      fontWeight: softenedT > 0.55 ? FontWeight.w700 : FontWeight.w500,
    );
  }
}
