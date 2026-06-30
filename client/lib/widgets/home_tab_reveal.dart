import 'package:flutter/material.dart';

class HomeTabRevealScope extends InheritedWidget {
  const HomeTabRevealScope({
    super.key,
    required this.animation,
    required this.serial,
    required super.child,
  });

  final Animation<double> animation;
  final int serial;

  static HomeTabRevealScope? maybeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<HomeTabRevealScope>();
  }

  @override
  bool updateShouldNotify(HomeTabRevealScope oldWidget) {
    return animation != oldWidget.animation || serial != oldWidget.serial;
  }
}

class HomeTabRevealItem extends StatelessWidget {
  const HomeTabRevealItem({
    super.key,
    required this.index,
    required this.child,
    this.enabled = true,
    this.maxDelayItems = 4,
  });

  final int index;
  final Widget child;
  final bool enabled;
  final int maxDelayItems;

  @override
  Widget build(BuildContext context) {
    final scope = HomeTabRevealScope.maybeOf(context);
    if (!enabled || scope == null) return child;

    final delay = index.clamp(0, maxDelayItems) * 0.032;
    final end = (delay + 0.84).clamp(0.0, 1.0);
    final curve = Interval(delay, end, curve: Curves.easeOutQuad);

    return AnimatedBuilder(
      animation: scope.animation,
      child: child,
      builder: (context, child) {
        final t = curve.transform(scope.animation.value.clamp(0.0, 1.0));
        return Opacity(
          opacity: 0.82 + 0.18 * t,
          child: Transform.translate(
            offset: Offset(0, 36 * (1 - t)),
            child: Transform.scale(
              scale: 0.985 + 0.015 * t,
              alignment: Alignment.topCenter,
              child: child,
            ),
          ),
        );
      },
    );
  }
}
