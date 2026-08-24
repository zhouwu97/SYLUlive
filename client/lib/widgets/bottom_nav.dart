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
import '../theme/app_motion.dart';
import '../theme/app_radius.dart';
import '../theme/app_text_styles.dart';
import 'liquid_glass/bottom_nav_controller.dart';
export 'liquid_glass/bottom_nav_controller.dart';
import 'liquid_glass/liquid_lens_geometry.dart';
export 'liquid_glass/liquid_lens_geometry.dart';
import 'liquid_glass/liquid_glass_runtime.dart';

const _navIcons = <IconData>[
  Icons.home_rounded,
  Icons.storefront_rounded,
  Icons.calendar_month_rounded,
  Icons.apartment_rounded,
  Icons.person_rounded,
];

const _navLabels = <String>['首页', '集市', '课表', '校园', '我'];
const _dockHeight = 64.0;
const _selectionHeight = 56.0;
const _tabContentPressedScale = 1.20;
const _pressSpring = SpringDescription(
  mass: 1,
  stiffness: 1000,
  damping: 63.2455532,
);

class _NavItemVisualState {
  const _NavItemVisualState({
    required this.color,
    required this.fontWeight,
    required this.scale,
  });

  final Color color;
  final FontWeight fontWeight;
  final double scale;
}

double _selectionPressProgress(double activation) {
  return Curves.easeOutCubic.transform(activation.clamp(0.0, 1.0).toDouble());
}

double _selectionVelocityFactor({
  required double velocityPixelsPerSecond,
  required double normalization,
}) {
  return (velocityPixelsPerSecond / math.max(normalization, 1.0))
      .clamp(-0.20, 0.20)
      .toDouble();
}

double _selectionScaleX({
  required double activation,
  required double velocityPixelsPerSecond,
  required LiquidGlassTuning tuning,
}) {
  final pressScale = ui.lerpDouble(
    1.0,
    tuning.pressedScale,
    _selectionPressProgress(activation),
  )!;
  final velocity = _selectionVelocityFactor(
    velocityPixelsPerSecond: velocityPixelsPerSecond,
    normalization: tuning.velocityNormalization,
  );
  return pressScale / math.max(0.70, 1.0 - velocity * 0.75);
}

double _selectionScaleY({
  required double activation,
  required double velocityPixelsPerSecond,
  required LiquidGlassTuning tuning,
}) {
  final pressScale = ui.lerpDouble(
    1.0,
    tuning.pressedScale,
    _selectionPressProgress(activation),
  )!;
  final velocity = _selectionVelocityFactor(
    velocityPixelsPerSecond: velocityPixelsPerSecond,
    normalization: tuning.velocityNormalization,
  );
  return pressScale * (1.0 - velocity * 0.25);
}

/// 页面只提交离散 Tab；底栏自己管理连续视觉位置和可中断弹簧。
class BottomNavWrapper extends StatefulWidget {
  final int currentIndex;
  final ValueNotifier<double> visualIndexListenable;
  final ValueChanged<int> onTap;
  final ValueChanged<int>? onNavigationCommitted;
  final ValueChanged<double>? onVisualPositionChanged;
  final VoidCallback? onInteractionStart;
  final ValueChanged<LiquidNavPhase>? onLiquidPhaseChanged;
  final ValueChanged<double>? onLiquidActivationChanged;
  final LiquidNavPhase? qaPhase;
  final double? qaActivation;
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
    this.onLiquidPhaseChanged,
    this.onLiquidActivationChanged,
    this.qaPhase,
    this.qaActivation,
    this.tuning = const LiquidGlassTuning(),
    this.badges = const {},
  });

  @override
  State<BottomNavWrapper> createState() => _BottomNavWrapperState();
}

class _BottomNavWrapperState extends State<BottomNavWrapper>
    with TickerProviderStateMixin {
  late final BottomNavController _controller;
  late final AnimationController _springController;
  late final AnimationController _activationController;
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
  bool _pointerInsideIdleSelection = false;
  bool _pointerInsideActiveLens = false;
  bool _isDragging = false;
  int _settleSerial = 0;
  LiquidNavPhase _phase = LiquidNavPhase.idle;
  double _activation = 0;
  int? _collapseTargetIndex;
  bool _commitAfterSettle = false;

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
    _activationController = AnimationController(
      vsync: this,
      duration: AppMotion.tab,
      reverseDuration: AppMotion.fast,
    )..addListener(_handleActivationTick);
  }

  @override
  void dispose() {
    _springController
      ..removeListener(_handleSpringTick)
      ..dispose();
    _activationController
      ..removeListener(_handleActivationTick)
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
            LayoutBuilder(
              builder: (context, constraints) {
                final dockSize = Size(constraints.maxWidth, _dockHeight);
                final itemWidth = dockSize.width / _navLabels.length;
                _itemWidth = itemWidth;
                _controller.configureTrack(
                  itemWidth: itemWidth,
                  trackLeft: itemWidth / 2,
                  trackRight: itemWidth * (_navLabels.length - 0.5),
                );

                return AnimatedBuilder(
                  animation: _visualFrameListenable,
                  builder: (context, child) {
                    final visualIndex = widget.visualIndexListenable.value;
                    final effectiveVisualIndex = reduceMotion && !_isDragging
                        ? widget.currentIndex.toDouble()
                        : visualIndex;
                    final phase = widget.qaPhase ?? _phase;
                    final activation =
                        (widget.qaActivation ?? _activation).clamp(0.0, 1.0);
                    final liquidVisible =
                        useLiquidGlass && phase != LiquidNavPhase.idle;
                    // QA 的 Dragging 状态没有真实 pointer velocity，使用固定预览值
                    // 让尾部、方向和边缘压缩仍然可被人工检查；生产路径继续读取真实速度。
                    final qaPreviewDragging =
                        widget.qaPhase == LiquidNavPhase.dragging;
                    final previewVelocityPixelsPerSecond = qaPreviewDragging
                        ? tuning.velocityNormalization * 0.72
                        : _velocityPixelsPerSecond;
                    final previewEdgeCompression =
                        qaPreviewDragging ? 0.16 : _controller.edgeCompression;
                    final idleSelectionIndex = phase == LiquidNavPhase.idle
                        ? effectiveVisualIndex
                        : (phase == LiquidNavPhase.collapsing &&
                                _collapseTargetIndex != null
                            ? _collapseTargetIndex!.toDouble()
                            : effectiveVisualIndex);

                    final selectionVelocity =
                        reduceMotion || phase != LiquidNavPhase.dragging
                            ? 0.0
                            : previewVelocityPixelsPerSecond;
                    final selectionEdgeCompression =
                        reduceMotion || phase != LiquidNavPhase.dragging
                            ? 0.0
                            : previewEdgeCompression;

                    return Stack(
                      clipBehavior: Clip.none,
                      children: [
                        SizedBox(
                          key: const ValueKey('bottom-nav-floating-dock'),
                          width: dockSize.width,
                          height: _dockHeight,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              borderRadius:
                                  BorderRadius.circular(AppRadius.pill),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(
                                    alpha: isDark ? 0.24 : 0.09,
                                  ),
                                  blurRadius: useLiquidGlass ? 18 : 16,
                                  offset: const Offset(0, 7),
                                ),
                              ],
                            ),
                            child: ClipRRect(
                              key: _dockRenderKey,
                              borderRadius:
                                  BorderRadius.circular(AppRadius.pill),
                              child: Stack(
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
                                                alpha:
                                                    highContrast ? 0.28 : 0.14,
                                              ),
                                              Colors.white.withValues(alpha: 0),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        _FloatingSelectionFallback(
                          itemWidth: itemWidth,
                          visualIndex: idleSelectionIndex,
                          isDark: isDark,
                          useLiquidGlass: useLiquidGlass,
                          surfaceAlpha: useLiquidGlass
                              ? ui.lerpDouble(0.10, 0.03, activation)!
                              : 1,
                          scaleX: useLiquidGlass
                              ? _selectionScaleX(
                                  activation: activation.toDouble(),
                                  velocityPixelsPerSecond: selectionVelocity,
                                  tuning: tuning,
                                )
                              : 1,
                          scaleY: useLiquidGlass
                              ? _selectionScaleY(
                                  activation: activation.toDouble(),
                                  velocityPixelsPerSecond: selectionVelocity,
                                  tuning: tuning,
                                )
                              : 1,
                        ),
                        Positioned.fill(
                          child: RepaintBoundary(
                            child: _buildGestureLayer(
                              context: context,
                              itemWidth: itemWidth,
                              visualIndex: effectiveVisualIndex,
                            ),
                          ),
                        ),
                        if (liquidVisible)
                          _FloatingAccentTabsLayer(
                            dockSize: dockSize,
                            itemWidth: itemWidth,
                            visualIndex: effectiveVisualIndex,
                            currentIndex: widget.currentIndex,
                            activation: activation.toDouble(),
                            scaleX: _selectionScaleX(
                              activation: activation.toDouble(),
                              velocityPixelsPerSecond: selectionVelocity,
                              tuning: tuning,
                            ),
                            scaleY: _selectionScaleY(
                              activation: activation.toDouble(),
                              velocityPixelsPerSecond: selectionVelocity,
                              tuning: tuning,
                            ),
                            accentColor: tuning.focusColorFor(isDark),
                            badges: widget.badges,
                          ),
                        if (liquidVisible)
                          _LiquidSelectionLens(
                            dockSize: dockSize,
                            itemWidth: itemWidth,
                            visualIndex: effectiveVisualIndex,
                            velocityPixelsPerSecond: selectionVelocity,
                            edgeCompression: selectionEdgeCompression,
                            phase: phase,
                            activation: activation.toDouble(),
                            pressDepth: phase == LiquidNavPhase.idle ? 0 : 1,
                            isDark: isDark,
                            highContrast: highContrast,
                            reduceMotion: reduceMotion,
                            tuning: tuning,
                          ),
                        if (!kReleaseMode)
                          Positioned(
                            left: 4,
                            bottom: _dockHeight + 4,
                            child: _LiquidGlassDiagnosticsOverlay(
                              visualPosition: widget.visualIndexListenable,
                              motionFrame: _motionFrame,
                              isDragging: phase == LiquidNavPhase.dragging,
                              phase: phase,
                              activation: activation.toDouble(),
                              velocityPixelsPerSecond:
                                  phase == LiquidNavPhase.dragging
                                      ? previewVelocityPixelsPerSecond
                                      : _velocityPixelsPerSecond,
                              itemWidth: itemWidth,
                              tuning: tuning,
                            ),
                          ),
                      ],
                    );
                  },
                );
              },
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
      onTapUp: (details) => _handleTapUp(details, itemWidth),
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
    // Android Emulator 的 Ctrl 多点模式会生成第二个对称触点；它不能
    // 接管当前 Lens，否则 VelocityTracker 和 grab offset 会被覆盖。
    if (_pointerId != null) return;
    final renderObject = _dockRenderKey.currentContext?.findRenderObject();
    final localX = renderObject is RenderBox
        ? renderObject.globalToLocal(event.position).dx
        : event.position.dx;
    _recordPointerDown(localX);
    _pointerId = event.pointer;
    _pointerDownTime = event.timeStamp;
    _lastPointerX = localX;
    _lastPointerTime = event.timeStamp;
    _velocityTracker = VelocityTracker.withKind(event.kind)
      ..addPosition(event.timeStamp, event.position);
    _pointerUpVelocityPixelsPerSecond = null;
    widget.onInteractionStart?.call();

    switch (_phase) {
      case LiquidNavPhase.idle:
        _cancelSpring();
        if (_pointerInsideIdleSelection) {
          _beginPress(localX);
        }
      case LiquidNavPhase.pressing:
        break;
      case LiquidNavPhase.dragging:
        break;
      case LiquidNavPhase.settling:
        _cancelSpring();
        if (_pointerInsideActiveLens) {
          _beginDrag(localX, event.timeStamp, regrab: true);
        } else {
          _startCollapse(widget.currentIndex);
        }
      case LiquidNavPhase.collapsing:
        if (_pointerInsideActiveLens) {
          _beginDrag(localX, event.timeStamp, regrab: true);
        }
    }
  }

  void _handlePointerMoveEvent(PointerMoveEvent event) {
    if (event.pointer != _pointerId) return;
    _velocityTracker?.addPosition(event.timeStamp, event.position);
    final localX = _localPointerX(event);

    if (_phase == LiquidNavPhase.pressing) {
      final downX = _pointerDownX;
      if (_pointerInsideIdleSelection &&
          downX != null &&
          (localX - downX).abs() >= 4) {
        _beginDrag(localX, event.timeStamp);
      }
      return;
    }

    if (_phase == LiquidNavPhase.dragging) {
      _updateDrag(localX, event.timeStamp);
    }
  }

  void _handlePointerUpEvent(PointerUpEvent event) {
    if (event.pointer != _pointerId) return;
    _velocityTracker?.addPosition(event.timeStamp, event.position);
    _pointerUpVelocityPixelsPerSecond =
        _velocityTracker?.getVelocity().pixelsPerSecond.dx;

    if (_phase == LiquidNavPhase.dragging) {
      _endDrag(
        _pointerUpVelocityPixelsPerSecond ?? _velocityPixelsPerSecond,
      );
    } else {
      final shouldCollapse = _phase == LiquidNavPhase.pressing;
      _clearPointerState();
      if (shouldCollapse) _startCollapse(widget.currentIndex);
    }
  }

  void _handlePointerCancelEvent(PointerCancelEvent event) {
    if (event.pointer != _pointerId) return;
    if (_phase == LiquidNavPhase.dragging) {
      _handleDragCancel();
    } else {
      final shouldCollapse = _phase == LiquidNavPhase.pressing;
      _clearPointerState();
      if (shouldCollapse) _startCollapse(widget.currentIndex);
    }
  }

  void _clearActivePointer() {
    _velocityTracker = null;
    _pointerId = null;
  }

  void _clearPointerState() {
    _pointerDownX = null;
    _pointerDownTime = null;
    _lastPointerTime = null;
    _pointerInsideIdleSelection = false;
    _pointerInsideActiveLens = false;
    _pointerUpVelocityPixelsPerSecond = null;
    _clearActivePointer();
  }

  void _recordPointerDown(double localX) {
    _pointerDownX = localX;
    _pointerInsideIdleSelection = _isPointInsideIdleSelection(localX);
    _pointerInsideActiveLens = _isPointInsideActiveLens(localX);
    _grabOffsetX = localX - _controller.lensCenterX;
  }

  void _handleTapUp(TapUpDetails details, double itemWidth) {
    _clearPointerState();
    widget.onTap(_indexForX(details.localPosition.dx, itemWidth));
  }

  double _localPointerX(PointerEvent event) {
    final renderObject = _dockRenderKey.currentContext?.findRenderObject();
    return renderObject is RenderBox
        ? renderObject.globalToLocal(event.position).dx
        : event.position.dx;
  }

  void _beginPress(double localX) {
    final currentIndex = widget.currentIndex.clamp(0, _navLabels.length - 1);
    _cancelSpring(resetPosition: currentIndex.toDouble());
    _grabOffsetX = localX - _controller.lensCenterX;
    _velocityPixelsPerSecond = 0;
    _collapseTargetIndex = null;
    _commitAfterSettle = false;
    _setVisualPosition(currentIndex.toDouble());
    _setPhase(LiquidNavPhase.pressing);
    _animateActivationTo(1);
  }

  void _beginDrag(
    double localX,
    Duration sourceTimeStamp, {
    bool regrab = false,
  }) {
    if (!regrab && !_pointerInsideIdleSelection) return;
    if (regrab && !_pointerInsideActiveLens) return;
    final startPosition = _controller.position;
    _controller.beginDrag(startPosition);
    _velocityPixelsPerSecond = _trackedVelocity() ?? 0;
    _lastPointerX = _pointerDownX ?? localX;
    _lastPointerTime = _pointerDownTime ?? sourceTimeStamp;
    _setPhase(LiquidNavPhase.dragging);
    _animateActivationTo(1);
    _controller.updateDragFromCenter(
      centerX: localX - _grabOffsetX,
      velocityPixelsPerSecond: _velocityPixelsPerSecond,
    );
    _setVisualPosition(_controller.position);
  }

  void _updateDrag(double x, Duration sourceTime) {
    if (!_isDragging) return;
    final previousTime = _lastPointerTime;
    final elapsedSeconds = previousTime != null
        ? math.max(
            (sourceTime - previousTime).inMicroseconds /
                Duration.microsecondsPerSecond,
            1 / 120,
          )
        : 1 / 60;
    final delta = x - _lastPointerX;
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

  void _endDrag(double velocity) {
    if (_phase != LiquidNavPhase.dragging) return;
    final target = _controller.endDrag(
      velocityPixelsPerSecond: velocity,
      itemWidth: _itemWidth,
    );
    _clearPointerState();
    _settleTo(
      target,
      velocity / _itemWidth,
      commit: true,
    );
  }

  void _handleDragCancel() {
    if (_phase != LiquidNavPhase.dragging) return;
    _clearPointerState();
    _controller.cancelDrag(widget.currentIndex.toDouble());
    _settleTo(widget.currentIndex, 0, commit: false);
  }

  void _settleTo(
    int target,
    double initialVelocity, {
    required bool commit,
  }) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final start = widget.visualIndexListenable.value
        .clamp(0.0, _navLabels.length - 1)
        .toDouble();
    final serial = ++_settleSerial;
    _springController.stop();
    _commitAfterSettle = commit;
    _collapseTargetIndex = target;
    _setPhase(LiquidNavPhase.settling);

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
    if (!mounted || _phase == LiquidNavPhase.dragging) return;
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
    final commit = _commitAfterSettle;
    _commitAfterSettle = false;
    if (commit) widget.onNavigationCommitted?.call(target);
    if (mounted) _startCollapse(target);
  }

  void _startCollapse(int target) {
    _collapseTargetIndex = target;
    _setPhase(LiquidNavPhase.collapsing);
    final reduced = MediaQuery.disableAnimationsOf(context);
    if (reduced) {
      _activationController.value = 0;
      _finishCollapse(target);
      return;
    }
    _animateActivationTo(0, onComplete: () => _finishCollapse(target));
  }

  void _finishCollapse(int target) {
    if (!mounted || _phase != LiquidNavPhase.collapsing) return;
    _activationController.value = 0;
    _controller.settle(target.toDouble());
    _setVisualPosition(target.toDouble());
    _collapseTargetIndex = null;
    _setPhase(LiquidNavPhase.idle);
  }

  void _cancelSpring({double? resetPosition}) {
    _settleSerial++;
    _springController.stop();
    final currentPosition =
        (resetPosition ?? widget.visualIndexListenable.value)
            .clamp(0.0, _navLabels.length - 1)
            .toDouble();
    _controller.settle(currentPosition);
    _velocityPixelsPerSecond = 0;
    if (resetPosition != null) _setVisualPosition(currentPosition);
  }

  void _handleActivationTick() {
    _activation = _activationController.value.clamp(0.0, 1.0).toDouble();
    widget.onLiquidActivationChanged?.call(_activation);
    _motionFrame.value++;
  }

  /// Press progress 使用可中断 spring，Pointer Up / re-grab 都从当前值继续，
  /// 不把选中态拆成“普通 indicator → 另一颗 Lens”。
  void _animateActivationTo(
    double target, {
    VoidCallback? onComplete,
  }) {
    final reduced = MediaQuery.disableAnimationsOf(context);
    _activationController.stop();
    if (reduced) {
      _activationController.value = target;
      onComplete?.call();
      return;
    }

    final simulation = SpringSimulation(
      _pressSpring,
      _activationController.value,
      target,
      0,
    );
    unawaited(
      _activationController.animateWith(simulation).then<void>((_) {
        onComplete?.call();
      }).catchError((Object _) {}),
    );
  }

  void _setPhase(LiquidNavPhase phase) {
    if (_phase == phase) return;
    _phase = phase;
    _isDragging = phase == LiquidNavPhase.dragging;
    widget.onLiquidPhaseChanged?.call(phase);
    if (mounted) setState(() {});
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

  bool _isPointInsideIdleSelection(double x) {
    final center =
        _controller.centerForPosition(widget.currentIndex.toDouble());
    return (x - center).abs() <= _itemWidth * 0.94 / 2;
  }

  bool _isPointInsideActiveLens(double x) {
    return (x - _controller.lensCenterX).abs() <= _activeLensWidth() / 2;
  }

  double _activeLensWidth() {
    return _itemWidth *
        _selectionScaleX(
          activation: _activation,
          velocityPixelsPerSecond:
              _phase == LiquidNavPhase.dragging ? _velocityPixelsPerSecond : 0,
          tuning: widget.tuning,
        );
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
          child: Transform.scale(
            // AndroidLiquidGlass 放大真实 Tab layer，而不是让 shader 把
            // 中央内容做 magnification；拖动时 focusWeight 连续迁移。
            scale: visualState.scale,
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
      ),
    );
  }

  _NavItemVisualState _visualStateFor({
    required BuildContext context,
    required int index,
    required double visualIndex,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final phase = widget.qaPhase ?? _phase;
    final activation =
        (widget.qaActivation ?? _activation).clamp(0.0, 1.0).toDouble();
    final focusWeight = liquidNavFocusWeight(
      currentIndex: widget.currentIndex,
      index: index,
      visualPosition: visualIndex,
      activation: activation,
    );
    final inactiveColor =
        isDark ? AppColors.iconMutedDark : AppColors.iconMutedLight;
    final focusColor = widget.tuning.focusColorFor(isDark);
    final pressedColor = widget.tuning.focusPressedColorFor(isDark);
    final pressSignal =
        phase == LiquidNavPhase.pressing || phase == LiquidNavPhase.dragging
            ? activation * 0.55
            : 0.0;
    final activeColor = Color.lerp(focusColor, pressedColor, pressSignal)!;
    return _NavItemVisualState(
      color: Color.lerp(inactiveColor, activeColor, focusWeight)!,
      fontWeight: FontWeight.w600,
      scale: ui.lerpDouble(
        1.0,
        _tabContentPressedScale,
        focusWeight * activation,
      )!,
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
    final surfaceColor = useLiquidGlass
        ? (isDark ? const Color(0xFF121212) : const Color(0xFFFAFAFA))
        : (isDark
            ? AppColors.surfaceSecondaryDark
            : AppColors.surfaceSecondaryLight);
    final surfaceAlpha =
        highContrast ? math.min(1.0, dockAlpha + 0.12) : dockAlpha;
    final fill = DecoratedBox(
      decoration: BoxDecoration(
        color: surfaceColor.withValues(
          alpha: useLiquidGlass ? surfaceAlpha : 1.0,
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
    required this.useLiquidGlass,
    required this.surfaceAlpha,
    required this.scaleX,
    required this.scaleY,
  });

  final double itemWidth;
  final double visualIndex;
  final bool isDark;
  final bool useLiquidGlass;
  final double surfaceAlpha;
  final double scaleX;
  final double scaleY;

  @override
  Widget build(BuildContext context) {
    final width = useLiquidGlass ? itemWidth : 56.0;
    final height = useLiquidGlass ? _selectionHeight : 48.0;
    final left = itemWidth * (visualIndex + 0.5) - width / 2;
    final decoration = useLiquidGlass
        ? BoxDecoration(
            color: (isDark ? Colors.white : Colors.black).withValues(
              alpha: surfaceAlpha.clamp(0.0, 1.0).toDouble(),
            ),
            borderRadius: BorderRadius.circular(AppRadius.pill),
            border: Border.all(
              color: Colors.white.withValues(alpha: isDark ? 0.12 : 0.18),
            ),
          )
        : BoxDecoration(
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
          );

    return Positioned(
      key: const ValueKey('bottom-nav-selection-fallback'),
      left: left,
      top: (_dockHeight - height) / 2,
      width: width,
      height: height,
      child: IgnorePointer(
        child: Transform.scale(
          alignment: Alignment.center,
          scaleX: scaleX,
          scaleY: scaleY,
          child: DecoratedBox(decoration: decoration),
        ),
      ),
    );
  }
}

/// Lens 专用的 accent 内容副本。
///
/// Flutter 没有 Compose `layerBackdrop` 的同名 API，因此这里把副本限制在
/// 当前 Capsule 的窗口内，再让后面的 shader 一起采样。Lens 外部不会出现一层
/// 常驻的彩色 Tab，拖动时颜色只会随着玻璃窗口移动。
class _FloatingAccentTabsLayer extends StatelessWidget {
  const _FloatingAccentTabsLayer({
    required this.dockSize,
    required this.itemWidth,
    required this.visualIndex,
    required this.currentIndex,
    required this.activation,
    required this.scaleX,
    required this.scaleY,
    required this.accentColor,
    required this.badges,
  });

  final Size dockSize;
  final double itemWidth;
  final double visualIndex;
  final int currentIndex;
  final double activation;
  final double scaleX;
  final double scaleY;
  final Color accentColor;
  final Map<int, bool> badges;

  @override
  Widget build(BuildContext context) {
    final width = itemWidth * scaleX;
    final height = _selectionHeight * scaleY;
    final left = itemWidth * (visualIndex + 0.5) - width / 2;
    final top = (_dockHeight - height) / 2;

    return Positioned(
      key: const ValueKey('bottom-nav-accent-tabs'),
      left: left,
      top: top,
      width: width,
      height: height,
      child: IgnorePointer(
        child: Opacity(
          opacity: activation.clamp(0.0, 1.0).toDouble(),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(math.min(width, height) / 2),
            child: OverflowBox(
              alignment: Alignment.topLeft,
              minWidth: dockSize.width,
              maxWidth: dockSize.width,
              minHeight: dockSize.height,
              maxHeight: dockSize.height,
              child: Transform.translate(
                offset: Offset(-left, -top),
                child: SizedBox(
                  width: dockSize.width,
                  height: dockSize.height,
                  child: _AccentTabsContent(
                    itemWidth: itemWidth,
                    visualIndex: visualIndex,
                    currentIndex: currentIndex,
                    activation: activation,
                    color: accentColor,
                    badges: badges,
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

class _AccentTabsContent extends StatelessWidget {
  const _AccentTabsContent({
    required this.itemWidth,
    required this.visualIndex,
    required this.currentIndex,
    required this.activation,
    required this.color,
    required this.badges,
  });

  final double itemWidth;
  final double visualIndex;
  final int currentIndex;
  final double activation;
  final Color color;
  final Map<int, bool> badges;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: Row(
        children: List.generate(
          _navLabels.length,
          (index) {
            final focusWeight = liquidNavFocusWeight(
              currentIndex: currentIndex,
              index: index,
              visualPosition: visualIndex,
              activation: activation,
            );
            final contentScale = ui.lerpDouble(
              1.0,
              _tabContentPressedScale,
              focusWeight * activation,
            )!;
            return SizedBox(
              width: itemWidth,
              height: _dockHeight,
              child: Transform.scale(
                scale: contentScale,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Icon(_navIcons[index], color: color, size: 24),
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
                      _navLabels[index],
                      maxLines: 1,
                      overflow: TextOverflow.visible,
                      style: AppTextStyles.labelMedium.copyWith(color: color),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _LiquidSelectionLens extends StatefulWidget {
  const _LiquidSelectionLens({
    required this.dockSize,
    required this.itemWidth,
    required this.visualIndex,
    required this.velocityPixelsPerSecond,
    required this.edgeCompression,
    required this.phase,
    required this.activation,
    required this.pressDepth,
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
  final LiquidNavPhase phase;
  final double activation;
  final double pressDepth;
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
    final speed = widget.reduceMotion || widget.phase != LiquidNavPhase.dragging
        ? 0.0
        : (widget.velocityPixelsPerSecond.abs() /
                math.max(widget.tuning.velocityNormalization, 1))
            .clamp(0.0, 1.0);
    final direction = widget.reduceMotion || speed < 0.01
        ? 0.0
        : widget.velocityPixelsPerSecond.sign;
    // Capsule 基准是“一格 × 56dp”；按压放大与拖动速度形变只作用于
    // 真实 Lens layer，几何轮廓始终是普通圆角矩形。
    final lensWidth = widget.itemWidth *
        _selectionScaleX(
          activation: widget.activation,
          velocityPixelsPerSecond: widget.velocityPixelsPerSecond,
          tuning: widget.tuning,
        );
    final lensHeight = _selectionHeight *
        _selectionScaleY(
          activation: widget.activation,
          velocityPixelsPerSecond: widget.velocityPixelsPerSecond,
          tuning: widget.tuning,
        );
    final requestedCenter = widget.itemWidth * (widget.visualIndex + 0.5);
    // Lens 已移到 Dock 的 ClipRRect 外层，中心仍严格跟随固定 Tab 轨道，
    // 不能为了完整显示而向内推首尾入口。
    final left = requestedCenter - lensWidth / 2;
    final top = (widget.dockSize.height - lensHeight) / 2;
    final visibleSize = Size(lensWidth, lensHeight);
    final overscanX = widget.tuning.overscanXFor(lensWidth);
    final overscanY = widget.tuning.overscanYFor(lensHeight);
    final captureSize = Size(
      lensWidth + overscanX * 2,
      lensHeight + overscanY * 2,
    );
    final captureLensCenter = Offset(
      overscanX + lensWidth / 2,
      overscanY + lensHeight / 2,
    );
    final shader = _shader;
    final canRefract = shader != null && ui.ImageFilter.isShaderFilterSupported;

    if (canRefract) {
      LiquidGlassShaderUniforms(
        captureSize: captureSize,
        lensCenter: captureLensCenter,
        lensSize: visibleSize,
        lensExponent: widget.tuning.lensExponent,
        refraction: widget.tuning.effectiveRefraction,
        magnification: widget.tuning.effectiveMagnification,
        chromatic: widget.tuning.effectiveChromatic,
        velocity: speed,
        direction: direction,
        edgeCompression: widget.edgeCompression,
        dragState: widget.tuning.mode == LiquidGlassQaMode.finalGlass &&
                widget.phase == LiquidNavPhase.dragging
            ? 1.0
            : 0.0,
        lightStrength: widget.tuning.effectiveLightStrength *
            (widget.highContrast ? 1.24 : 1.0),
        rimStrength: widget.tuning.effectiveRimStrength *
            (widget.highContrast ? 1.3 : 1.0),
        verticalRefractionScale: widget.tuning.verticalRefractionScale,
        refractionBandStart: widget.tuning.refractionBandStart,
        refractionBandPeak: widget.tuning.refractionBandPeak,
        refractionBandEnd: widget.tuning.refractionBandEnd,
        magnificationRadius: widget.tuning.magnificationRadius,
        chromaticStart: widget.tuning.chromaticStart,
        flowStrength: widget.tuning.flowStrength,
        activation: widget.activation,
        pressDepth: widget.pressDepth,
      ).apply(shader);
    }

    final bodyAlpha = ui.lerpDouble(0.10, 0.03, widget.activation)!;
    final bodyColor = (widget.isDark ? Colors.white : Colors.black).withValues(
      alpha: bodyAlpha,
    );
    final lensRadius =
        BorderRadius.circular(math.min(lensWidth, lensHeight) / 2);

    return Positioned(
      key: const ValueKey('bottom-nav-liquid-lens'),
      left: left,
      top: top,
      width: lensWidth,
      height: lensHeight,
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: lensRadius,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(
                  alpha: (widget.isDark ? 0.18 : 0.10) * widget.activation,
                ),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Stack(
            clipBehavior: Clip.none,
            fit: StackFit.expand,
            children: [
              ClipRRect(
                borderRadius: lensRadius,
                child: Stack(
                  clipBehavior: Clip.none,
                  fit: StackFit.expand,
                  children: [
                    if (canRefract)
                      Positioned(
                        left: -overscanX,
                        top: -overscanY,
                        width: captureSize.width,
                        height: captureSize.height,
                        child: BackdropFilter(
                          filter: ui.ImageFilter.shader(shader),
                          // shader 只在边缘改采样；中央会返回原图。
                          child: const SizedBox.expand(),
                        ),
                      )
                    else
                      Positioned.fill(
                        child: BackdropFilter(
                          filter: ui.ImageFilter.blur(
                            sigmaX: widget.tuning.dockBlur
                                .clamp(0.0, 20.0)
                                .toDouble(),
                            sigmaY: widget.tuning.dockBlur
                                .clamp(0.0, 20.0)
                                .toDouble(),
                          ),
                          child: const SizedBox.expand(),
                        ),
                      ),
                    Positioned.fill(child: ColoredBox(color: bodyColor)),
                    CustomPaint(
                      painter: _LiquidLensRimPainter(
                        isDark: widget.isDark,
                        highContrast: widget.highContrast,
                        motion: speed,
                        direction: direction,
                        edgeCompression: widget.edgeCompression,
                        lensExponent: widget.tuning.lensExponent,
                        flowStrength: widget.tuning.flowStrength,
                        rimStrength: widget.tuning.effectiveRimStrength *
                            widget.activation,
                        showShapeOutline:
                            widget.tuning.mode == LiquidGlassQaMode.shapeOnly,
                      ),
                    ),
                  ],
                ),
              ),
              if (widget.tuning.showCaptureBounds)
                Positioned(
                  left: -overscanX,
                  top: -overscanY,
                  width: captureSize.width,
                  height: captureSize.height,
                  child: CustomPaint(
                    painter: _LiquidLensBoundsPainter(
                      visibleOffset: Offset(overscanX, overscanY),
                      visibleSize: visibleSize,
                      speed: speed,
                      direction: direction,
                      edgeCompression: widget.edgeCompression,
                      lensExponent: widget.tuning.lensExponent,
                      flowStrength: widget.tuning.flowStrength,
                    ),
                  ),
                ),
            ],
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
    required this.lensExponent,
    required this.flowStrength,
    required this.rimStrength,
    required this.showShapeOutline,
  });

  final bool isDark;
  final bool highContrast;
  final double motion;
  final double direction;
  final double edgeCompression;
  final double lensExponent;
  final double flowStrength;
  final double rimStrength;
  final bool showShapeOutline;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(
      rect,
      Radius.circular(math.min(size.width, size.height) / 2),
    );
    if (showShapeOutline) {
      final outline = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = Colors.cyanAccent.withValues(alpha: 0.76);
      canvas.drawRRect(rrect, outline);
      return;
    }

    if (rimStrength <= 0) return;

    final strength = (rimStrength / 0.12).clamp(0.4, 1.4).toDouble();
    final highlight = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = highContrast ? 0.8 : 0.7
      ..strokeCap = StrokeCap.round
      ..color = Color.lerp(
        Colors.white,
        const Color(0xFFD9F5FF),
        0.32,
      )!
          .withValues(
        alpha: (highContrast ? 0.24 : 0.20) * strength,
      );
    // Capsule 顶部一段高光；避免用完整白描边把主体画成硬塑料。
    canvas.drawArc(
      rect.deflate(highlight.strokeWidth / 2),
      math.pi * 1.05,
      math.pi * 0.62,
      false,
      highlight,
    );

    final innerShadow = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = highContrast ? 1.35 : 1.0
      ..color = Colors.black.withValues(
        alpha: (highContrast ? 0.14 : 0.08) * strength,
      )
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.5);
    canvas.drawRRect(rrect.deflate(0.8), innerShadow);

    // 轻微的冷/暖侧缘与运动方向绑定，真正的色散仍由 shader 完成。
    final dispersion = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.55
      ..strokeCap = StrokeCap.round
      ..color =
          (direction < 0 ? const Color(0xFFB8DFFF) : const Color(0xFFFFD99A))
              .withValues(alpha: 0.12 * strength);
    canvas.drawArc(
      rect.deflate(1.0),
      direction < 0 ? math.pi * 0.42 : math.pi * 1.58,
      math.pi * 0.22,
      false,
      dispersion,
    );
  }

  @override
  bool shouldRepaint(covariant _LiquidLensRimPainter oldDelegate) {
    return oldDelegate.isDark != isDark ||
        oldDelegate.highContrast != highContrast ||
        oldDelegate.motion != motion ||
        oldDelegate.direction != direction ||
        oldDelegate.edgeCompression != edgeCompression ||
        oldDelegate.lensExponent != lensExponent ||
        oldDelegate.flowStrength != flowStrength ||
        oldDelegate.rimStrength != rimStrength ||
        oldDelegate.showShapeOutline != showShapeOutline;
  }
}

class _LiquidLensBoundsPainter extends CustomPainter {
  const _LiquidLensBoundsPainter({
    required this.visibleOffset,
    required this.visibleSize,
    required this.speed,
    required this.direction,
    required this.edgeCompression,
    required this.lensExponent,
    required this.flowStrength,
  });

  final Offset visibleOffset;
  final Size visibleSize;
  final double speed;
  final double direction;
  final double edgeCompression;
  final double lensExponent;
  final double flowStrength;

  @override
  void paint(Canvas canvas, Size size) {
    final capturePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8
      ..color = Colors.redAccent.withValues(alpha: 0.75);
    final visiblePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0
      ..color = Colors.cyanAccent.withValues(alpha: 0.9);
    canvas.drawRect(Offset.zero & size, capturePaint);
    canvas.drawPath(
      LiquidLensShape.pathForSize(
        visibleSize,
        speed: speed,
        direction: direction,
        edgeCompression: edgeCompression,
        lensExponent: lensExponent,
        flowStrength: flowStrength,
      ).shift(visibleOffset),
      visiblePaint,
    );
  }

  @override
  bool shouldRepaint(covariant _LiquidLensBoundsPainter oldDelegate) {
    return oldDelegate.visibleOffset != visibleOffset ||
        oldDelegate.visibleSize != visibleSize ||
        oldDelegate.speed != speed ||
        oldDelegate.direction != direction ||
        oldDelegate.edgeCompression != edgeCompression ||
        oldDelegate.lensExponent != lensExponent ||
        oldDelegate.flowStrength != flowStrength;
  }
}

/// 开发/性能包可见的渲染诊断。它故意放在 Dock 外部，避免把诊断文字
/// 混进 Lens 的采样纹理，也不会拦截手势。
class _LiquidGlassDiagnosticsOverlay extends StatelessWidget {
  const _LiquidGlassDiagnosticsOverlay({
    required this.visualPosition,
    required this.motionFrame,
    required this.isDragging,
    required this.phase,
    required this.activation,
    required this.velocityPixelsPerSecond,
    required this.itemWidth,
    required this.tuning,
  });

  final ValueNotifier<double> visualPosition;
  final ValueNotifier<int> motionFrame;
  final bool isDragging;
  final LiquidNavPhase phase;
  final double activation;
  final double velocityPixelsPerSecond;
  final double itemWidth;
  final LiquidGlassTuning tuning;

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
          final lensWidth = itemWidth *
              _selectionScaleX(
                activation: activation,
                velocityPixelsPerSecond: phase == LiquidNavPhase.dragging
                    ? velocityPixelsPerSecond
                    : 0,
                tuning: tuning,
              );
          final lensHeight = _selectionHeight *
              _selectionScaleY(
                activation: activation,
                velocityPixelsPerSecond: phase == LiquidNavPhase.dragging
                    ? velocityPixelsPerSecond
                    : 0,
                tuning: tuning,
              );
          final overscanX = tuning.overscanXFor(lensWidth);
          final overscanY = tuning.overscanYFor(lensHeight);
          final maxOffsetX = tuning.maxSampleOffsetXFor(lensWidth);
          final maxOffsetY = tuning.maxSampleOffsetYFor(lensHeight);
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
                  'Phase: ${phase.name}  Activation: '
                  '${activation.toStringAsFixed(2)}\n'
                  'Dragging: $isDragging  '
                  'Position: ${visualPosition.value.toStringAsFixed(3)}  '
                  'Velocity: ${velocityPixelsPerSecond.round()} px/s\n'
                  'Visible: ${lensWidth.round()}×${lensHeight.round()}  '
                  'Capture: ${(lensWidth + overscanX * 2).round()}×'
                  '${(lensHeight + overscanY * 2).round()}  '
                  'Overscan: ${overscanX.round()}×${overscanY.round()}\n'
                  'Max sample: ${maxOffsetX.toStringAsFixed(1)}×'
                  '${maxOffsetY.toStringAsFixed(1)} px',
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
