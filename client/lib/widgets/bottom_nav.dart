import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/theme_provider.dart';

class BottomNavWrapper extends StatelessWidget {
  final int currentIndex;
  final Function(int) onTap;
  final AuthProvider authProvider;

  const BottomNavWrapper({
    super.key,
    required this.currentIndex,
    required this.onTap,
    required this.authProvider,
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
    final primaryColor = Theme.of(context).primaryColor;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
            child: Container(
              padding: EdgeInsets.only(top: 4, bottom: 2 + bottomSafe),
              decoration: BoxDecoration(
                color: (isDark ? const Color(0xFF1A1A2E) : Colors.white)
                    .withValues(alpha: 0.85),
                border: Border(
                  top: BorderSide(
                    color: isDark ? Colors.white10 : Colors.black.withValues(alpha: 0.06),
                    width: 0.5,
                  ),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  _labeledItem(Icons.home_rounded, '首页', 0, context, primaryColor),
                  _labeledItem(Icons.storefront_rounded, '集市', 1, context, primaryColor),
                  _labeledItem(Icons.calendar_month_rounded, '课表', 2, context, primaryColor),
                  _labeledItem(Icons.apartment_rounded, '校园', 3, context, primaryColor),
                  _labeledItem(Icons.person_rounded, '我', 4, context, primaryColor),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  // 悬浮模式：胶囊毛玻璃（纯图标）
  Widget _buildFloatingNav(BuildContext context, bool isDark) {
    final primaryColor = Theme.of(context).primaryColor;
    final bottomSafe = MediaQuery.of(context).padding.bottom;

    return GestureDetector(
      onHorizontalDragEnd: (details) {
        if (details.primaryVelocity == null) return;
        if (currentIndex > 0 && details.primaryVelocity! > 200) {
          onTap(currentIndex - 1);
        } else if (currentIndex < 4 && details.primaryVelocity! < -200) {
          onTap(currentIndex + 1);
        }
      },
      child: Container(
        margin: EdgeInsets.only(left: 12, right: 12, top: 8, bottom: 8 + bottomSafe),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(50),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: (isDark ? Colors.grey[900]! : Colors.white)
                    .withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(50),
                border: Border.all(
                  color: isDark ? Colors.white10 : Colors.white30,
                  width: 1,
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  _iconOnly(Icons.home_rounded, 0, context, primaryColor),
                  _iconOnly(Icons.storefront_rounded, 1, context, primaryColor),
                  _iconOnly(Icons.calendar_month_rounded, 2, context, primaryColor),
                  _iconOnly(Icons.apartment_rounded, 3, context, primaryColor),
                  _iconOnly(Icons.person_rounded, 4, context, primaryColor),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // 标准模式 Item（图标+文字）
  Widget _labeledItem(IconData icon, String label, int index, BuildContext context, Color primaryColor) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isSelected = currentIndex == index;
    final color = isSelected ? primaryColor : (isDark ? Colors.white54 : Colors.grey);
    return GestureDetector(
      onTap: () => onTap(index),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 2),
        child: Column(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(height: 1),
          Text(label, style: TextStyle(color: color, fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500, fontSize: 10)),
        ]),
      ),
    );
  }

  // 悬浮模式 Item（纯图标）
  Widget _iconOnly(IconData icon, int index, BuildContext context, Color primaryColor) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isSelected = currentIndex == index;
    final color = isSelected ? primaryColor : (isDark ? Colors.white54 : Colors.grey);

    return GestureDetector(
      onTap: () => onTap(index),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeInOutCubicEmphasized,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: isSelected ? primaryColor.withValues(alpha: 0.12) : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Icon(icon, color: color, size: 28),
      ),
    );
  }
}
