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
    this.revealOrder,
    this.delayStep = 0.055,
    this.initialOffset = 56,
    this.initialOpacity = 0.80,
    this.initialScale = 0.984,
    this.curve = Curves.easeOutCubic,
    this.maxDelayItems = 7,
  });

  final int index;
  final Widget child;
  final bool enabled;
  final int? revealOrder;
  final double delayStep;
  final double initialOffset;
  final double initialOpacity;
  final double initialScale;
  final Curve curve;
  final int maxDelayItems;

  @override
  Widget build(BuildContext context) {
    final scope = HomeTabRevealScope.maybeOf(context);
    if (!enabled || scope == null) return child;

    final order = (revealOrder ?? index).clamp(0, maxDelayItems);
    final delay = order * delayStep;
    final end = (delay + 0.84).clamp(0.0, 1.0);
    final revealCurve = Interval(delay, end, curve: curve);

    return AnimatedBuilder(
      animation: scope.animation,
      child: child,
      builder: (context, child) {
        final t = revealCurve.transform(scope.animation.value.clamp(0.0, 1.0));
        return Opacity(
          opacity: initialOpacity + (1 - initialOpacity) * t,
          child: Transform.translate(
            offset: Offset(0, initialOffset * (1 - t)),
            child: Transform.scale(
              scale: initialScale + (1 - initialScale) * t,
              alignment: Alignment.topCenter,
              child: child,
            ),
          ),
        );
      },
    );
  }
}
