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

    return _buildStandardNav(context, isDark);
  }

  Widget _buildStandardNav(BuildContext context, bool isDark) {
    return Container(
      decoration: BoxDecoration(
        color:
            Theme.of(context).scaffoldBackgroundColor.withValues(alpha: 0.95),
        border: Border(
          top: BorderSide(
            color: Theme.of(context).dividerColor.withValues(alpha: 0.1),
            width: 0.5,
          ),
        ),
      ),
      child: NavigationBar(
        selectedIndex: currentIndex,
        onDestinationSelected: onTap,
        backgroundColor: Colors.transparent,
        elevation: 0,
        animationDuration: const Duration(milliseconds: 420),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: '首页',
          ),
          NavigationDestination(
            icon: Icon(Icons.store_outlined),
            selectedIcon: Icon(Icons.store),
            label: '集市',
          ),
          NavigationDestination(
            icon: Icon(Icons.calendar_today_outlined),
            selectedIcon: Icon(Icons.calendar_today),
            label: '课表',
          ),
          NavigationDestination(
            icon: Icon(Icons.leaderboard_outlined),
            selectedIcon: Icon(Icons.leaderboard),
            label: '榜单',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outlined),
            selectedIcon: Icon(Icons.person),
            label: '我',
          ),
        ],
      ),
    );
  }

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
        margin: const EdgeInsets.all(16),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(30),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              decoration: BoxDecoration(
                color: (isDark ? Colors.grey[900]! : Colors.white)
                    .withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(30),
                border: Border.all(
                  color: isDark ? Colors.white10 : Colors.white30,
                  width: 1,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _buildFloatingItem(0, Icons.home, Icons.home_outlined, '首页',
                      context, primaryColor),
                  _buildFloatingItem(1, Icons.store, Icons.store_outlined, '集市',
                      context, primaryColor),
                  _buildFloatingItem(
                      2,
                      Icons.calendar_today,
                      Icons.calendar_today_outlined,
                      '课表',
                      context,
                      primaryColor),
                  _buildFloatingItem(3, Icons.leaderboard,
                      Icons.leaderboard_outlined, '榜单', context, primaryColor),
                  _buildFloatingItem(4, Icons.person, Icons.person_outlined,
                      '我', context, primaryColor),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFloatingItem(int index, IconData selectedIcon, IconData icon,
      String label, BuildContext context, Color primaryColor) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isSelected = currentIndex == index;
    final color =
        isSelected ? primaryColor : (isDark ? Colors.white54 : Colors.grey);

    return GestureDetector(
      onTap: () => onTap(index),
      child: SizedBox(
        width: 60,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeInOutCubicEmphasized,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          decoration: BoxDecoration(
            color: isSelected
                ? primaryColor.withValues(alpha: 0.15)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedScale(
                duration: const Duration(milliseconds: 320),
                curve: Curves.easeInOutCubicEmphasized,
                scale: isSelected ? 1.08 : 1,
                child: Icon(
                  isSelected ? selectedIcon : icon,
                  color: color,
                  size: 21,
                ),
              ),
              const SizedBox(height: 3),
              AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 320),
                curve: Curves.easeInOutCubicEmphasized,
                style: TextStyle(
                  color: color,
                  fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                  fontSize: 10.5,
                ),
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
