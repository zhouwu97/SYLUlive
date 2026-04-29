import 'package:flutter/material.dart';
import 'dart:ui';

class AuthExpiredOverlay extends StatefulWidget {
  final VoidCallback onDismiss;
  final VoidCallback onRelogin;

  const AuthExpiredOverlay({
    super.key,
    required this.onDismiss,
    required this.onRelogin,
  });

  @override
  State<AuthExpiredOverlay> createState() => _AuthExpiredOverlayState();
}

class _AuthExpiredOverlayState extends State<AuthExpiredOverlay>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnimation;
  late Animation<Offset> _slideAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _fadeAnimation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );
    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, 0.1),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return FadeTransition(
      opacity: _fadeAnimation,
      child: SlideTransition(
        position: _slideAnimation,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Material(
              borderRadius: BorderRadius.circular(20),
              color: Colors.transparent,
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: isDark
                        ? [
                            const Color(0xFF1A1A2E).withOpacity(0.95),
                            const Color(0xFF16213E).withOpacity(0.95),
                          ]
                        : [
                            Colors.white.withOpacity(0.95),
                            Colors.white.withOpacity(0.9),
                          ],
                  ),
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: isDark
                          ? Colors.black.withOpacity(0.5)
                          : Colors.purple.withOpacity(0.2),
                      blurRadius: 30,
                      spreadRadius: 5,
                    ),
                  ],
                  border: Border.all(
                    color: isDark
                        ? Colors.white.withOpacity(0.1)
                        : Colors.purple.withOpacity(0.2),
                    width: 1,
                  ),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    colors: [
                                      Colors.orange[400]!,
                                      Colors.red[400]!,
                                    ],
                                  ),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: const Icon(
                                  Icons.warning_amber_rounded,
                                  color: Colors.white,
                                  size: 28,
                                ),
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '登录已过期',
                                      style: TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.bold,
                                        color: isDark
                                            ? Colors.white
                                            : Colors.black87,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      '请重新登录以继续使用',
                                      style: TextStyle(
                                        fontSize: 13,
                                        color: isDark
                                            ? Colors.white60
                                            : Colors.black54,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              IconButton(
                                onPressed: widget.onDismiss,
                                icon: Icon(
                                  Icons.close,
                                  color: isDark
                                      ? Colors.white60
                                      : Colors.black38,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 20),
                          Row(
                            children: [
                              Expanded(
                                child: _GlassButton(
                                  onPressed: widget.onDismiss,
                                  isDark: isDark,
                                  child: const Text('暂时不管'),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: _GradientButton(
                                  onPressed: widget.onRelogin,
                                  colors: [
                                    Colors.purple[400]!,
                                    Colors.purple[600]!,
                                  ],
                                  child: const Text(
                                    '重新登录',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _GlassButton extends StatelessWidget {
  final VoidCallback onPressed;
  final bool isDark;
  final Widget child;

  const _GlassButton({
    required this.onPressed,
    required this.isDark,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            color: isDark
                ? Colors.white.withOpacity(0.1)
                : Colors.black.withOpacity(0.05),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isDark
                  ? Colors.white.withOpacity(0.2)
                  : Colors.black.withOpacity(0.1),
            ),
          ),
          child: Center(child: child),
        ),
      ),
    );
  }
}

class _GradientButton extends StatelessWidget {
  final VoidCallback onPressed;
  final List<Color> colors;
  final Widget child;

  const _GradientButton({
    required this.onPressed,
    required this.colors,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: colors,
            ),
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: colors[0].withOpacity(0.4),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Center(child: child),
        ),
      ),
    );
  }
}

class AuthExpiredManager {
  static bool _shownThisSession = false;

  static void resetSessionFlag() {
    _shownThisSession = false;
  }

  static bool shouldShow() {
    if (_shownThisSession) {
      return false;
    }
    _shownThisSession = true;
    return true;
  }

  static OverlayEntry? _currentOverlay;

  static void show(BuildContext context, {required VoidCallback onDismiss, required VoidCallback onRelogin}) {
    if (!shouldShow()) return;

    final overlay = Overlay.of(context);
    _currentOverlay?.remove();

    _currentOverlay = OverlayEntry(
      builder: (context) => Positioned(
        bottom: 100,
        left: 16,
        right: 16,
        child: AuthExpiredOverlay(
          onDismiss: () {
            _currentOverlay?.remove();
            _currentOverlay = null;
            onDismiss();
          },
          onRelogin: () {
            _currentOverlay?.remove();
            _currentOverlay = null;
            onRelogin();
          },
        ),
      ),
    );

    overlay.insert(_currentOverlay!);
  }

  static void dismiss() {
    _currentOverlay?.remove();
    _currentOverlay = null;
  }
}