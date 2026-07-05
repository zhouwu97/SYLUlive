import 'package:flutter/material.dart';

class SectionFloatingDock extends StatelessWidget {
  final Color accentColor;
  final bool isDark;
  final bool isRefreshing;
  final bool compact;
  final VoidCallback onRefresh;
  final VoidCallback onCompose;

  const SectionFloatingDock({
    super.key,
    required this.accentColor,
    required this.isDark,
    required this.isRefreshing,
    required this.compact,
    required this.onRefresh,
    required this.onCompose,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        _buildRefreshButton(),
        const SizedBox(height: 10),
        _buildComposeButton(),
      ],
    );
  }

  Widget _buildRefreshButton() {
    return GestureDetector(
      onTap: isRefreshing ? null : onRefresh,
      child: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: isDark
              ? Colors.white.withValues(alpha: 0.1)
              : Colors.white.withValues(alpha: 0.8),
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.08),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
          border: Border.all(
            color: isDark ? Colors.white.withValues(alpha: 0.05) : Colors.white,
            width: 1,
          ),
        ),
        child: Center(
          child: isRefreshing
              ? SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(
                        isDark ? Colors.white70 : Colors.black54),
                  ),
                )
              : Icon(
                  Icons.refresh_rounded,
                  size: 20,
                  color: isDark ? Colors.white70 : Colors.black54,
                ),
        ),
      ),
    );
  }

  Widget _buildComposeButton() {
    return GestureDetector(
      onTap: onCompose,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeInOut,
        width: compact ? 52 : 76,
        height: compact ? 52 : 48,
        decoration: BoxDecoration(
          color: accentColor,
          borderRadius: BorderRadius.circular(compact ? 26 : 24),
          boxShadow: [
            BoxShadow(
              color: accentColor.withValues(alpha: 0.25),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.add_rounded,
                color: Colors.white,
                size: 24,
              ),
              if (!compact) ...[
                const SizedBox(width: 4),
                const Text(
                  '发帖',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
