import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import '../providers/theme_provider.dart';
import '../theme/app_colors.dart';
import '../theme/app_radius.dart';
import '../theme/app_text_styles.dart';
import 'liquid_glass/bottom_nav_controller.dart';
import 'liquid_glass/liquid_glass_runtime.dart';

const _navIcons = <IconData>[
  Icons.home_rounded,
  Icons.storefront_rounded,
  Icons.calendar_month_rounded,
  Icons.apartment_rounded,
  Icons.person_rounded,
];

const _navLabels = <String>['首页', '集市', '课表', '校园', '我'];
const _dockHeight = 66.0;

class _NavItemVisualState {
  const _NavItemVisualState({
    required this.color,
    required this.fontWeight,
  });

  final Color color;
  final FontWeight fontWeight;
}

/// 页面只提交离散 Tab；底栏自己管理连续视觉位置和可中断弹簧。
class BottomNavWrapper extends StatefulWidget {
  final int currentIndex;
  final ValueNotifier<double> visualIndexListenable;
  final ValueChanged<int> onTap;
  final ValueChanged<int>? onNavigationCommitted;
  final ValueChanged<double>? onVisualPositionChanged;
  final VoidCallback? onInteractionStart;
  final LiquidGlassTuning tuning;
  final AuthProvider authProvider;
  final Map<int, bool> badges;

  const BottomNavWrapper({
    super.key,
    required this.currentIndex,
    required this.visualIndexListenable,
    required this.onTap,
    required this.authProvider,
    this.onNavigationCommitted,
    this.onVisualPositionChanged,
    this.onInteractionStart,
    this.tuning = const LiquidGlassTuning(),
    this.badges = const {},
  });

  @override
  State<BottomNavWrapper> createState() => _BottomNavWrapperState();
}

class _BottomNavWrapperState extends State<BottomNavWrapper>
    with SingleTickerProviderStateMixin {
  late final BottomNavController _controller;
  late final AnimationController _springController;
  late final ValueNotifier<int> _motionFrame;
  late final Listenable _visualFrameListenable;

  double _itemWidth = 1;
  double _velocityPixelsPerSecond = 0;
  double _lastPointerX = 0;
  Duration? _lastPointerTime;
  double? _pointerDownX;
  Duration? _pointerDownTime;
  int? _pointerId;
  VelocityTracker? _velocityTracker;
  double? _pointerUpVelocityPixelsPerSecond;
  double _grabOffsetX = 0;
  final GlobalKey _dockRenderKey = GlobalKey();
  bool _pointerInsideLens = false;
  bool _isDragging = false;
  int _settleSerial = 0;

  @override
  void initState() {
    super.initState();
    final initialPosition = widget.visualIndexListenable.value
        .clamp(0.0, _navLabels.length - 1)
        .toDouble();
    _controller = BottomNavController(
      itemCount: _navLabels.length,
      initialIndex: widget.currentIndex.clamp(0, _navLabels.length - 1),
    )..position = initialPosition;
    _motionFrame = ValueNotifier(0);
    _visualFrameListenable = Listenable.merge([
      widget.visualIndexListenable,
      _motionFrame,
    ]);
    _springController = AnimationController.unbounded(
      vsync: this,
      value: initialPosition,
    )..addListener(_handleSpringTick);
  }

  @override
  void dispose() {
    _springController
      ..removeListener(_handleSpringTick)
      ..dispose();
    _motionFrame.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final themeProvider = context.watch<ThemeProvider>();

    if (themeProvider.floatingNavBar) {
      return _buildFloatingNav(
        context,
        isDark,
        themeProvider.liquidGlass,
        tuning: widget.tuning,
      );
    }
    return _buildBlurNav(context, isDark);
  }

  // 标准模式保留原有逐项点击导航；连续 Lens 只属于悬浮 Dock。
  Widget _buildBlurNav(BuildContext context, bool isDark) {
    final bottomSafe = MediaQuery.of(context).padding.bottom;
    return LayoutBuilder(
      builder: (context, constraints) {
        final itemWidth = constraints.maxWidth / _navLabels.length;
        return ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          child: Container(
            padding: EdgeInsets.only(
              top: 2,
              bottom: bottomSafe > 0 ? bottomSafe : 2,
            ),
            decoration: BoxDecoration(
              color: (isDark ? AppColors.surfaceSecondaryDark : Colors.white)
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
                Positioned.fill(
                  child: RepaintBoundary(
                    child: ValueListenableBuilder<double>(
                      valueListenable: widget.visualIndexListenable,
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
                                        AppColors.brandPrimary
                                            .withValues(alpha: 0.18),
                                        AppColors.brandPrimary
                                            .withValues(alpha: 0.07),
                                      ],
                                    ),
                                    borderRadius: BorderRadius.circular(14),
                                    border: Border.all(
                                      color: AppColors.brandPrimary
                                          .withValues(alpha: 0.1),
                                    ),
                                    boxShadow: [
                                      BoxShadow(
                                        color: AppColors.brandPrimary
                                            .withValues(alpha: 0.12),
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
                ),
                Row(
                  children: List.generate(
                    _navLabels.length,
                    (index) => _standardItem(
                      icon: _navIcons[index],
                      label: _navLabels[index],
                      index: index,
                      context: context,
                      width: itemWidth,
                      visualIndex: widget.visualIndexListenable.value,
                      showBadge: widget.badges[index] == true,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildFloatingNav(
    BuildContext context,
    bool isDark,
    bool useLiquidGlass, {
    required LiquidGlassTuning tuning,
  }) {
    final mediaQuery = MediaQuery.of(context);
    final highContrast = mediaQuery.highContrast;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    const dockHorizontalInset = 12.0;
    const dockBottomInset = 8.0;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          dockHorizontalInset,
          0,
          dockHorizontalInset,
          dockBottomInset,
        ),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            SizedBox(
              key: const ValueKey('bottom-nav-floating-dock'),
              height: _dockHeight,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                  boxShadow: [
                    BoxShadow(
                      color:
                          Colors.black.withValues(alpha: isDark ? 0.24 : 0.09),
                      blurRadius: useLiquidGlass ? 18 : 16,
                      offset: const Offset(0, 7),
                    ),
                  ],
                ),
                child: ClipRRect(
                  key: _dockRenderKey,
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final dockSize = Size(constraints.maxWidth, _dockHeight);
                      final itemWidth = dockSize.width / _navLabels.length;
                      _itemWidth = itemWidth;
                      _controller.configureTrack(
                        itemWidth: itemWidth,
                        trackLeft: itemWidth / 2,
                        trackRight: itemWidth * (_navLabels.length - 0.5),
                      );

                      return Stack(
                        alignment: Alignment.center,
                        children: [
                          Positioned.fill(
                            child: _FloatingDockSurface(
                              isDark: isDark,
                              highContrast: highContrast,
                              useLiquidGlass: useLiquidGlass,
                              tuning: tuning,
                            ),
                          ),
                          Positioned.fill(
                            child: RepaintBoundary(
                              child: AnimatedBuilder(
                                animation: _visualFrameListenable,
                                builder: (context, child) {
                                  final visualIndex =
                                      widget.visualIndexListenable.value;
                                  final effectiveVisualIndex =
                                      reduceMotion && !_isDragging
                                          ? widget.currentIndex.toDouble()
                                          : visualIndex;
                                  return Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      if (!useLiquidGlass)
                                        _FloatingSelectionFallback(
                                          itemWidth: itemWidth,
                                          visualIndex: effectiveVisualIndex,
                                          isDark: isDark,
                                        ),
                                      _buildGestureLayer(
                                        context: context,
                                        itemWidth: itemWidth,
                                        visualIndex: effectiveVisualIndex,
                                      ),
                                      if (useLiquidGlass)
                                        _LiquidSelectionLens(
                                          dockSize: dockSize,
                                          itemWidth: itemWidth,
                                          visualIndex: effectiveVisualIndex,
                                          velocityPixelsPerSecond: reduceMotion
                                              ? 0
                                              : _velocityPixelsPerSecond,
                                          edgeCompression: reduceMotion
                                              ? 0
                                              : _controller.edgeCompression,
                                          isDragging: _isDragging,
                                          isDark: isDark,
                                          highContrast: highContrast,
                                          reduceMotion: reduceMotion,
                                          tuning: tuning,
                                        ),
                                    ],
                                  );
                                },
                              ),
                            ),
                          ),
                          Positioned(
                            top: 0,
                            left: _dockHeight * 0.55,
                            right: _dockHeight * 0.55,
                            height: 1,
                            child: IgnorePointer(
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    colors: [
                                      Colors.white.withValues(alpha: 0),
                                      Colors.white.withValues(
                                        alpha: highContrast ? 0.72 : 0.42,
                                      ),
                                      Colors.white.withValues(alpha: 0),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
            if (!kReleaseMode)
              Positioned(
                left: 4,
                bottom: _dockHeight + 4,
                child: _LiquidGlassDiagnosticsOverlay(
                  visualPosition: widget.visualIndexListenable,
                  motionFrame: _motionFrame,
                  isDragging: _isDragging,
                  velocityPixelsPerSecond: _velocityPixelsPerSecond,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildGestureLayer({
    required BuildContext context,
    required double itemWidth,
    required double visualIndex,
  }) {
    return GestureDetector(
      key: const ValueKey('bottom-nav-gesture-layer'),
      behavior: HitTestBehavior.opaque,
      onTapDown: (details) {
        _recordPointerDown(details.localPosition.dx);
      },
      onTapUp: (details) => _handleTapUp(details, itemWidth),
      onHorizontalDragStart: (details) => _handleDragStart(details, itemWidth),
      onHorizontalDragUpdate: (details) =>
          _handleDragUpdate(details, itemWidth),
      onHorizontalDragEnd: (details) => _handleDragEnd(details, itemWidth),
      onHorizontalDragCancel: _handleDragCancel,
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: _handlePointerDownEvent,
        onPointerMove: _handlePointerMoveEvent,
        onPointerUp: _handlePointerUpEvent,
        onPointerCancel: _handlePointerCancelEvent,
        child: Row(
          children: List.generate(
            _navLabels.length,
            (index) => _floatingItem(
              icon: _navIcons[index],
              label: _navLabels[index],
              index: index,
              context: context,
              width: itemWidth,
              visualIndex: visualIndex,
              showBadge: widget.badges[index] == true,
            ),
          ),
        ),
      ),
    );
  }

  void _handlePointerDownEvent(PointerDownEvent event) {
    final renderObject = _dockRenderKey.currentContext?.findRenderObject();
    final localX = renderObject is RenderBox
        ? renderObject.globalToLocal(event.position).dx
        : event.position.dx;
    _recordPointerDown(localX);
    _pointerId = event.pointer;
    _pointerDownTime = event.timeStamp;
    _velocityTracker = VelocityTracker.withKind(event.kind)
      ..addPosition(event.timeStamp, event.position);
    _pointerUpVelocityPixelsPerSecond = null;
    _cancelSpring();
    widget.onInteractionStart?.call();
  }

  void _handlePointerMoveEvent(PointerMoveEvent event) {
    if (event.pointer != _pointerId) return;
    _velocityTracker?.addPosition(event.timeStamp, event.position);
  }

  void _handlePointerUpEvent(PointerUpEvent event) {
    if (event.pointer != _pointerId) return;
    _velocityTracker?.addPosition(event.timeStamp, event.position);
    _pointerUpVelocityPixelsPerSecond =
        _velocityTracker?.getVelocity().pixelsPerSecond.dx;
  }

  void _handlePointerCancelEvent(PointerCancelEvent event) {
    if (event.pointer != _pointerId) return;
    _velocityTracker = null;
    _pointerId = null;
    _pointerUpVelocityPixelsPerSecond = null;
  }

  void _recordPointerDown(double localX) {
    _pointerDownX = localX;
    _pointerInsideLens = _isPointInsideLens(localX);
    _grabOffsetX = localX - _controller.lensCenterX;
  }

  void _handleTapUp(TapUpDetails details, double itemWidth) {
    _pointerDownX = null;
    _pointerDownTime = null;
    _pointerInsideLens = false;
    widget.onTap(_indexForX(details.localPosition.dx, itemWidth));
  }

  void _handleDragStart(DragStartDetails details, double itemWidth) {
    if (!_pointerInsideLens) return;
    _cancelSpring();
    final startPosition = _controller.position;
    _controller.beginDrag(startPosition);
    _velocityPixelsPerSecond = _trackedVelocity() ?? 0;
    _lastPointerX = _pointerDownX ?? details.localPosition.dx;
    _lastPointerTime = _pointerDownTime ?? details.sourceTimeStamp;
    setState(() => _isDragging = true);
    _controller.updateDragFromCenter(
      centerX: details.localPosition.dx - _grabOffsetX,
      velocityPixelsPerSecond: _velocityPixelsPerSecond,
    );
    _setVisualPosition(_controller.position);
  }

  void _handleDragUpdate(DragUpdateDetails details, double itemWidth) {
    if (!_isDragging) return;
    final x = details.localPosition.dx;
    final sourceTime = details.sourceTimeStamp;
    final previousTime = _lastPointerTime;
    final elapsedSeconds = sourceTime != null && previousTime != null
        ? math.max(
            (sourceTime - previousTime).inMicroseconds /
                Duration.microsecondsPerSecond,
            1 / 120,
          )
        : 1 / 60;
    final delta = details.primaryDelta ?? (x - _lastPointerX);
    final instantaneousVelocity = delta / elapsedSeconds;
    final trackedVelocity = _trackedVelocity() ?? instantaneousVelocity;
    _velocityPixelsPerSecond =
        _velocityPixelsPerSecond * 0.72 + trackedVelocity * 0.28;
    _lastPointerX = x;
    _lastPointerTime = sourceTime;

    _controller.updateDragFromCenter(
      centerX: x - _grabOffsetX,
      velocityPixelsPerSecond: _velocityPixelsPerSecond,
    );
    _setVisualPosition(_controller.position);
  }

  void _handleDragEnd(DragEndDetails details, double itemWidth) {
    if (!_isDragging) return;
    final velocity = _pointerUpVelocityPixelsPerSecond ??
        details.primaryVelocity ??
        _velocityPixelsPerSecond;
    final target = _controller.endDrag(
      velocityPixelsPerSecond: velocity,
      itemWidth: itemWidth,
    );
    _pointerDownX = null;
    _pointerDownTime = null;
    _lastPointerTime = null;
    _pointerInsideLens = false;
    _pointerUpVelocityPixelsPerSecond = null;
    _settleTo(target, velocity / itemWidth);
  }

  void _handleDragCancel() {
    if (!_isDragging) return;
    _pointerDownX = null;
    _pointerDownTime = null;
    _pointerInsideLens = false;
    _pointerUpVelocityPixelsPerSecond = null;
    _controller.cancelDrag(widget.currentIndex.toDouble());
    _settleTo(widget.currentIndex, 0);
  }

  void _settleTo(int target, double initialVelocity) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final start = widget.visualIndexListenable.value
        .clamp(0.0, _navLabels.length - 1)
        .toDouble();
    final serial = ++_settleSerial;
    _springController.stop();

    if (reduceMotion || (start - target).abs() < 0.001) {
      _finishSettle(serial, target);
      return;
    }

    _springController.value = start;
    final simulation = SpringSimulation(
      const SpringDescription(mass: 1, stiffness: 320, damping: 24),
      start,
      target.toDouble(),
      initialVelocity,
    );
    unawaited(
      _springController.animateWith(simulation).then<void>((_) {
        _finishSettle(serial, target);
      }).catchError((Object _) {}),
    );
  }

  void _handleSpringTick() {
    if (!mounted || _isDragging) return;
    final rawPosition = _springController.value;
    final position = rawPosition.clamp(0.0, _navLabels.length - 1).toDouble();
    _controller.position = position;
    _controller.lensCenterX = _controller.centerForPosition(position);
    _controller.edgeCompression =
        (rawPosition - position).abs().clamp(0.0, 1.0);
    _velocityPixelsPerSecond = _springController.velocity * _itemWidth;
    _setVisualPosition(position);
  }

  void _finishSettle(int serial, int target) {
    if (!mounted || serial != _settleSerial) return;
    _controller.settle(target.toDouble());
    _velocityPixelsPerSecond = 0;
    _setVisualPosition(target.toDouble());
    if (_isDragging) {
      setState(() => _isDragging = false);
    }
    widget.onNavigationCommitted?.call(target);
  }

  void _cancelSpring() {
    _settleSerial++;
    _springController.stop();
    final currentPosition = widget.visualIndexListenable.value
        .clamp(0.0, _navLabels.length - 1)
        .toDouble();
    _controller.settle(currentPosition);
    _velocityPixelsPerSecond = 0;
  }

  void _setVisualPosition(double position) {
    final next = position.clamp(0.0, _navLabels.length - 1).toDouble();
    _controller.position = next;
    _controller.lensCenterX = _controller.centerForPosition(next);
    if ((widget.visualIndexListenable.value - next).abs() > 0.0001) {
      widget.visualIndexListenable.value = next;
    }
    // 位置被边界 clamp 后仍要重绘 edgeCompression / velocity 形变；不让
    // “手指继续向屏幕边缘拖”因为 position 没变化而丢失视觉反馈。
    _motionFrame.value++;
    widget.onVisualPositionChanged?.call(next);
  }

  int _indexForX(double x, double itemWidth) {
    return _controller
        .positionForCenter(x)
        .round()
        .clamp(0, _navLabels.length - 1);
  }

  double? _trackedVelocity() {
    final velocity = _velocityTracker?.getVelocity().pixelsPerSecond.dx;
    if (velocity == null || !velocity.isFinite) return null;
    return velocity;
  }

  bool _isPointInsideLens(double x) {
    final speed = MediaQuery.disableAnimationsOf(context)
        ? 0.0
        : (_velocityPixelsPerSecond.abs() / 1400).clamp(0.0, 1.0);
    final width = math.max(84.0, _itemWidth * 1.35) *
        (1 + speed * 0.12 - _controller.edgeCompression * 0.08);
    return (x - _controller.lensCenterX).abs() <= width / 2;
  }

  Widget _standardItem({
    required IconData icon,
    required String label,
    required int index,
    required BuildContext context,
    required double width,
    required double visualIndex,
    required bool showBadge,
  }) {
    final visualState = _visualStateFor(
      context: context,
      index: index,
      visualIndex: visualIndex,
    );
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => widget.onTap(index),
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

  Widget _floatingItem({
    required IconData icon,
    required String label,
    required int index,
    required BuildContext context,
    required double width,
    required double visualIndex,
    required bool showBadge,
  }) {
    final visualState = _visualStateFor(
      context: context,
      index: index,
      visualIndex: visualIndex,
    );
    return Semantics(
      key: ValueKey('bottom-nav-item-$index'),
      button: true,
      selected: widget.currentIndex == index,
      label: label,
      child: ExcludeSemantics(
        child: SizedBox(
          width: width,
          height: double.infinity,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Icon(icon, color: visualState.color, size: 24),
                  if (showBadge)
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
                label,
                maxLines: 1,
                overflow: TextOverflow.visible,
                style: AppTextStyles.labelMedium.copyWith(
                  color: visualState.color,
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
    required double visualIndex,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final activeT = (1 - (visualIndex - index).abs()).clamp(0.0, 1.0);
    final softenedT = Curves.easeOutCubic.transform(activeT);
    final inactiveColor =
        isDark ? AppColors.iconMutedDark : AppColors.iconMutedLight;
    return _NavItemVisualState(
      color: Color.lerp(inactiveColor, AppColors.brandPrimary, softenedT)!,
      fontWeight: FontWeight.w600,
    );
  }
}

class _FloatingDockSurface extends StatelessWidget {
  const _FloatingDockSurface({
    required this.isDark,
    required this.highContrast,
    required this.useLiquidGlass,
    required this.tuning,
  });

  final bool isDark;
  final bool highContrast;
  final bool useLiquidGlass;
  final LiquidGlassTuning tuning;

  @override
  Widget build(BuildContext context) {
    final dockAlpha = tuning.dockAlpha.clamp(0.0, 1.0).toDouble();
    final fill = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: useLiquidGlass
              ? (isDark
                  ? [
                      const Color(0xFF202326).withValues(
                        alpha: (highContrast ? 0.32 : 0.25) * dockAlpha,
                      ),
                      const Color(0xFF111315).withValues(
                        alpha: (highContrast ? 0.27 : 0.18) * dockAlpha,
                      ),
                    ]
                  : [
                      Colors.white.withValues(
                        alpha: (highContrast ? 0.26 : 0.18) * dockAlpha,
                      ),
                      Colors.white.withValues(
                        alpha: (highContrast ? 0.18 : 0.10) * dockAlpha,
                      ),
                    ])
              : (isDark
                  ? [
                      AppColors.surfaceSecondaryDark,
                      AppColors.surfaceSecondaryDark,
                    ]
                  : [
                      AppColors.surfaceSecondaryLight,
                      AppColors.surfaceSecondaryLight,
                    ]),
        ),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: highContrast ? 0.22 : 0.10)
              : (useLiquidGlass
                  ? Colors.white.withValues(
                      alpha: (highContrast ? 0.46 : 0.26) * dockAlpha,
                    )
                  : AppColors.borderNormalLight),
          width: highContrast ? 1.25 : 1,
        ),
      ),
    );

    if (!useLiquidGlass) return fill;
    return BackdropFilter(
      filter: ui.ImageFilter.blur(
        sigmaX: isDark
            ? tuning.dockBlur.clamp(0.0, 20.0).toDouble() + 1
            : tuning.dockBlur.clamp(0.0, 20.0).toDouble(),
        sigmaY: isDark
            ? tuning.dockBlur.clamp(0.0, 20.0).toDouble() + 1
            : tuning.dockBlur.clamp(0.0, 20.0).toDouble(),
      ),
      child: fill,
    );
  }
}

class _FloatingSelectionFallback extends StatelessWidget {
  const _FloatingSelectionFallback({
    required this.itemWidth,
    required this.visualIndex,
    required this.isDark,
  });

  final double itemWidth;
  final double visualIndex;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    const width = 56.0;
    const height = 48.0;
    final left = itemWidth * (visualIndex + 0.5) - width / 2;
    return Positioned(
      key: const ValueKey('bottom-nav-selection-fallback'),
      left: left,
      top: (_dockHeight - height) / 2,
      width: width,
      height: height,
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: isDark
                  ? [
                      AppColors.brandPrimary.withValues(alpha: 0.28),
                      AppColors.brandPrimary.withValues(alpha: 0.12),
                    ]
                  : [
                      const Color(0xFFF3FBF8),
                      const Color(0xFFE5F5F0),
                    ],
            ),
            borderRadius: BorderRadius.circular(AppRadius.pill),
            border: Border.all(
              color: AppColors.brandPrimary.withValues(
                alpha: isDark ? 0.30 : 0.14,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Lens 的唯一几何来源。BackdropFilter 的裁剪和顶部 glint 都复用这条
/// Path，避免出现“外轮廓已经变形、边缘绘制仍是固定胶囊”的错觉。
class LiquidLensShape {
  const LiquidLensShape._();

  static Path pathForSize(
    Size size, {
    required double speed,
    required double direction,
    required double edgeCompression,
  }) {
    final width = size.width;
    final height = size.height;
    final motion = speed.clamp(0.0, 1.0).toDouble();
    final sign = direction.sign;
    final edge = edgeCompression.clamp(0.0, 1.0).toDouble();
    final tail = width * motion * 0.085;
    final bulge = width * motion * 0.065;
    final verticalLift = height * motion * 0.055;
    final leftInset = sign < 0 ? width * edge * 0.09 : 0.0;
    final rightInset = sign > 0 ? width * edge * 0.09 : 0.0;
    final left = leftInset;
    final right = width - rightInset;
    final top = height * (0.10 - motion * 0.018);
    final bottom = height - top;

    final path = Path()..moveTo(width * 0.22 - sign * tail, top);
    path.cubicTo(
      width * 0.38 - sign * tail * 0.72,
      top - verticalLift,
      width * 0.64 + sign * bulge * 0.42,
      top - verticalLift * 0.55,
      width * 0.80 + sign * bulge * 0.58,
      top,
    );
    path.cubicTo(
      right + sign * bulge,
      height * 0.19,
      right + sign * bulge * 0.82,
      height * 0.37,
      right,
      height * 0.50,
    );
    path.cubicTo(
      right + sign * bulge * 0.82,
      height * 0.63,
      right + sign * bulge,
      height * 0.81,
      width * 0.80 + sign * bulge * 0.58,
      bottom,
    );
    path.cubicTo(
      width * 0.62 + sign * bulge * 0.42,
      bottom + verticalLift * 0.55,
      width * 0.38 - sign * tail * 0.72,
      bottom + verticalLift,
      width * 0.22 - sign * tail,
      bottom,
    );
    path.cubicTo(
      left - sign * tail,
      height * 0.81,
      left - sign * tail * 0.72,
      height * 0.63,
      left,
      height * 0.50,
    );
    path.cubicTo(
      left - sign * tail * 0.72,
      height * 0.37,
      left - sign * tail,
      height * 0.19,
      width * 0.22 - sign * tail,
      top,
    );
    return path..close();
  }
}

class LiquidLensClipper extends CustomClipper<Path> {
  const LiquidLensClipper({
    required this.speed,
    required this.direction,
    required this.edgeCompression,
  });

  final double speed;
  final double direction;
  final double edgeCompression;

  @override
  Path getClip(Size size) => LiquidLensShape.pathForSize(
        size,
        speed: speed,
        direction: direction,
        edgeCompression: edgeCompression,
      );

  @override
  bool shouldReclip(covariant LiquidLensClipper oldClipper) {
    return oldClipper.speed != speed ||
        oldClipper.direction != direction ||
        oldClipper.edgeCompression != edgeCompression;
  }
}

class _LiquidSelectionLens extends StatefulWidget {
  const _LiquidSelectionLens({
    required this.dockSize,
    required this.itemWidth,
    required this.visualIndex,
    required this.velocityPixelsPerSecond,
    required this.edgeCompression,
    required this.isDragging,
    required this.isDark,
    required this.highContrast,
    required this.reduceMotion,
    required this.tuning,
  });

  final Size dockSize;
  final double itemWidth;
  final double visualIndex;
  final double velocityPixelsPerSecond;
  final double edgeCompression;
  final bool isDragging;
  final bool isDark;
  final bool highContrast;
  final bool reduceMotion;
  final LiquidGlassTuning tuning;

  @override
  State<_LiquidSelectionLens> createState() => _LiquidSelectionLensState();
}

class _LiquidSelectionLensState extends State<_LiquidSelectionLens> {
  static Future<ui.FragmentProgram?>? _programFuture;
  ui.FragmentShader? _shader;

  @override
  void initState() {
    super.initState();
    _loadShader();
  }

  static Future<ui.FragmentProgram?> _program() {
    return _programFuture ??= () async {
      if (!ui.ImageFilter.isShaderFilterSupported) {
        updateLiquidGlassRuntimeStatus(
          tier: LiquidGlassTier.c,
          shaderSupported: false,
          detail: 'ImageFilter.shader unsupported',
        );
        debugPrint('[LiquidGlass] renderer=fallback tier=C shader=false');
        return null;
      }
      try {
        final program = await ui.FragmentProgram.fromAsset(
          'shaders/liquid_nav_lens.frag',
        );
        updateLiquidGlassRuntimeStatus(
          tier: LiquidGlassTier.a,
          shaderSupported: true,
          detail: 'FragmentShader + ImageFilter.shader',
        );
        debugPrint('[LiquidGlass] renderer=shader tier=A impeller=unknown');
        return program;
      } catch (error) {
        updateLiquidGlassRuntimeStatus(
          tier: LiquidGlassTier.c,
          shaderSupported: true,
          detail: 'shader compile/load failed',
        );
        debugPrint('[LiquidGlass] renderer=fallback tier=C error=$error');
        return null;
      }
    }();
  }

  Future<void> _loadShader() async {
    final program = await _program();
    if (!mounted || program == null) return;
    setState(() => _shader = program.fragmentShader());
  }

  @override
  void dispose() {
    _shader?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final speed = widget.reduceMotion
        ? 0.0
        : (widget.velocityPixelsPerSecond.abs() / 1400).clamp(0.0, 1.0);
    final direction = widget.reduceMotion || speed < 0.01
        ? 0.0
        : widget.velocityPixelsPerSecond.sign;
    final baseWidth = math.max(84.0, widget.itemWidth * 1.35);
    final lensWidth = baseWidth *
        (1 + speed * 0.12 - widget.edgeCompression.clamp(0.0, 1.0) * 0.08);
    final lensHeight = 56.0 * (1 + speed * 0.025);
    final requestedCenter = widget.itemWidth * (widget.visualIndex + 0.5);
    // Lens 可以被 Dock 的 ClipRRect 裁掉外缘，但中心永远跟随固定 Tab
    // 轨道，不能为了完整显示而向内推首尾入口。
    final left = requestedCenter - lensWidth / 2;
    final top = (widget.dockSize.height - lensHeight) / 2;
    final shader = _shader;
    final canRefract = shader != null && ui.ImageFilter.isShaderFilterSupported;

    if (canRefract) {
      shader
        ..setFloat(2, widget.tuning.refraction)
        ..setFloat(3, widget.tuning.magnification)
        ..setFloat(4, widget.tuning.chromatic)
        ..setFloat(5, speed)
        ..setFloat(6, direction)
        ..setFloat(7, widget.edgeCompression)
        ..setFloat(8, widget.isDragging ? 1.0 : 0.0)
        ..setFloat(9, 1.0)
        ..setFloat(10, 1.0)
        ..setFloat(11, 1.0)
        ..setFloat(12, widget.isDark ? 0.045 : 0.03)
        ..setFloat(
          13,
          widget.tuning.lightStrength * (widget.highContrast ? 1.24 : 1.0),
        )
        ..setFloat(
          14,
          widget.tuning.rimStrength * (widget.highContrast ? 1.3 : 1.0),
        );
    }

    final filter = canRefract
        ? ui.ImageFilter.shader(shader)
        : ui.ImageFilter.blur(
            sigmaX: widget.tuning.dockBlur.clamp(0.0, 20.0).toDouble(),
            sigmaY: widget.tuning.dockBlur.clamp(0.0, 20.0).toDouble(),
          );

    return Positioned(
      key: const ValueKey('bottom-nav-liquid-lens'),
      left: left,
      top: top,
      width: lensWidth,
      height: lensHeight,
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.pill),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(
                  alpha: widget.isDark ? 0.20 : 0.08,
                ),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: ClipPath(
            clipper: LiquidLensClipper(
              speed: speed,
              direction: direction,
              edgeCompression: widget.edgeCompression,
            ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                BackdropFilter(
                  filter: filter,
                  child: ColoredBox(
                    color: canRefract
                        ? const Color(0x01000000)
                        : (widget.isDark
                            ? Colors.white.withValues(alpha: 0.07)
                            : Colors.white.withValues(alpha: 0.14)),
                  ),
                ),
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Colors.white.withValues(
                          alpha: widget.isDark ? 0.07 : 0.045,
                        ),
                        Colors.transparent,
                        Colors.black.withValues(
                          alpha: widget.isDark ? 0.045 : 0.018,
                        ),
                      ],
                    ),
                  ),
                ),
                CustomPaint(
                  painter: _LiquidLensRimPainter(
                    isDark: widget.isDark,
                    highContrast: widget.highContrast,
                    motion: speed,
                    direction: direction,
                    edgeCompression: widget.edgeCompression,
                    rimStrength: widget.tuning.rimStrength,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LiquidLensRimPainter extends CustomPainter {
  const _LiquidLensRimPainter({
    required this.isDark,
    required this.highContrast,
    required this.motion,
    required this.direction,
    required this.edgeCompression,
    required this.rimStrength,
  });

  final bool isDark;
  final bool highContrast;
  final double motion;
  final double direction;
  final double edgeCompression;
  final double rimStrength;

  @override
  void paint(Canvas canvas, Size size) {
    final highlight = Path()
      ..moveTo(size.width * 0.20 - direction * motion * size.width * 0.04,
          size.height * 0.105)
      ..cubicTo(
        size.width * 0.36,
        size.height * (0.045 - motion * 0.015),
        size.width * 0.64 + direction * motion * size.width * 0.05,
        size.height * (0.045 - motion * 0.015),
        size.width * 0.80 + direction * motion * size.width * 0.04,
        size.height * 0.105,
      );
    final highlightPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = highContrast ? 0.85 : 0.55
      ..shader = LinearGradient(
        colors: [
          Colors.white.withValues(alpha: 0),
          Colors.white.withValues(
            alpha: ((highContrast ? 0.36 : 0.18) + motion * 0.08) *
                rimStrength.clamp(0.0, 2.0),
          ),
          Colors.white.withValues(alpha: 0),
        ],
      ).createShader(Offset.zero & size);
    canvas.drawPath(highlight, highlightPaint);
  }

  @override
  bool shouldRepaint(covariant _LiquidLensRimPainter oldDelegate) {
    return oldDelegate.isDark != isDark ||
        oldDelegate.highContrast != highContrast ||
        oldDelegate.motion != motion ||
        oldDelegate.direction != direction ||
        oldDelegate.edgeCompression != edgeCompression ||
        oldDelegate.rimStrength != rimStrength;
  }
}

/// 开发/性能包可见的渲染诊断。它故意放在 Dock 外部，避免把诊断文字
/// 混进 Lens 的采样纹理，也不会拦截手势。
class _LiquidGlassDiagnosticsOverlay extends StatelessWidget {
  const _LiquidGlassDiagnosticsOverlay({
    required this.visualPosition,
    required this.motionFrame,
    required this.isDragging,
    required this.velocityPixelsPerSecond,
  });

  final ValueNotifier<double> visualPosition;
  final ValueNotifier<int> motionFrame;
  final bool isDragging;
  final double velocityPixelsPerSecond;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: Listenable.merge([
          visualPosition,
          motionFrame,
          liquidGlassRuntimeStatus,
        ]),
        builder: (context, child) {
          final status = liquidGlassRuntimeStatus.value;
          return DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.68),
              borderRadius: BorderRadius.circular(7),
              border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
              child: DefaultTextStyle(
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 9,
                  height: 1.15,
                  fontFeatures: [ui.FontFeature.tabularFigures()],
                ),
                child: Text(
                  'Liquid Glass  Tier: ${status.tierLabel}  '
                  'Shader: ${status.shaderSupported}\n'
                  'Dragging: $isDragging  '
                  'Position: ${visualPosition.value.toStringAsFixed(3)}  '
                  'Velocity: ${velocityPixelsPerSecond.round()} px/s',
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
