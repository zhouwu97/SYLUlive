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

  // 标准模式：毛玻璃底栏
  Widget _buildBlurNav(BuildContext context, bool isDark) {
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
        child: Container(
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
          child: SafeArea(
            top: false,
            child: NavigationBar(
            selectedIndex: currentIndex,
            onDestinationSelected: onTap,
            backgroundColor: Colors.transparent,
            elevation: 0,
            height: 60,
            animationDuration: const Duration(milliseconds: 300),
            indicatorShape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
            labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.home_outlined, size: 20),
                selectedIcon: Icon(Icons.home, size: 20),
                label: '首页',
              ),
              NavigationDestination(
                icon: Icon(Icons.store_outlined, size: 20),
                selectedIcon: Icon(Icons.store, size: 20),
                label: '集市',
              ),
              NavigationDestination(
                icon: Icon(Icons.calendar_today_outlined, size: 20),
                selectedIcon: Icon(Icons.calendar_today, size: 20),
                label: '课表',
              ),
              NavigationDestination(
                icon: Icon(Icons.leaderboard_outlined, size: 20),
                selectedIcon: Icon(Icons.leaderboard, size: 20),
                label: '榜单',
              ),
              NavigationDestination(
                icon: Icon(Icons.person_outlined, size: 20),
                selectedIcon: Icon(Icons.person, size: 20),
                label: '我',
              ),
            ],
          ),
          ),
        ),
      ),
    );
  }

  // 悬浮模式
  Widget _buildFloatingNav(BuildContext context, bool isDark) {
    final primaryColor = Theme.of(context).primaryColor;

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
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
              decoration: BoxDecoration(
                color: (isDark ? Colors.grey[900]! : Colors.white)
                    .withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: isDark ? Colors.white10 : Colors.white30,
                  width: 1,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _buildItem(0, Icons.home, Icons.home_outlined, '首页', context, primaryColor),
                  _buildItem(1, Icons.store, Icons.store_outlined, '集市', context, primaryColor),
                  _buildItem(2, Icons.calendar_today, Icons.calendar_today_outlined, '课表', context, primaryColor),
                  _buildItem(3, Icons.leaderboard, Icons.leaderboard_outlined, '榜单', context, primaryColor),
                  _buildItem(4, Icons.person, Icons.person_outlined, '我', context, primaryColor),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildItem(int index, IconData selectedIcon, IconData icon,
      String label, BuildContext context, Color primaryColor) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isSelected = currentIndex == index;
    final color = isSelected ? primaryColor : (isDark ? Colors.white54 : Colors.grey);

    return GestureDetector(
      onTap: () => onTap(index),
      child: SizedBox(
        width: 58,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeInOutCubicEmphasized,
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 5),
          decoration: BoxDecoration(
            color: isSelected
                ? primaryColor.withValues(alpha: 0.12)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedScale(
                duration: const Duration(milliseconds: 280),
                curve: Curves.easeInOutCubicEmphasized,
                scale: isSelected ? 1.06 : 1,
                child: Icon(
                  isSelected ? selectedIcon : icon,
                  color: color,
                  size: 20,
                ),
              ),
              const SizedBox(height: 2),
              AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 280),
                curve: Curves.easeInOutCubicEmphasized,
                style: TextStyle(
                  color: color,
                  fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                  fontSize: 9.5,
                ),
                child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
