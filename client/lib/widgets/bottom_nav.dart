import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import '../providers/theme_provider.dart';
import '../theme/app_colors.dart';
import '../theme/app_radius.dart';
import '../theme/app_text_styles.dart';
import 'liquid_glass/bottom_nav_controller.dart';

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
      return _buildFloatingNav(context, isDark, themeProvider.liquidGlass);
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
    bool useLiquidGlass,
  ) {
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
        child: SizedBox(
          key: const ValueKey('bottom-nav-floating-dock'),
          height: _dockHeight,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadius.pill),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.24 : 0.09),
                  blurRadius: useLiquidGlass ? 18 : 16,
                  offset: const Offset(0, 7),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.pill),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final dockSize = Size(constraints.maxWidth, _dockHeight);
                  final itemWidth = dockSize.width / _navLabels.length;
                  _itemWidth = itemWidth;

                  return Stack(
                    alignment: Alignment.center,
                    children: [
                      Positioned.fill(
                        child: _FloatingDockSurface(
                          isDark: isDark,
                          highContrast: highContrast,
                          useLiquidGlass: useLiquidGlass,
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
        _pointerDownX = details.localPosition.dx;
        _pointerDownTime = null;
      },
      onTapUp: (details) => _handleTapUp(details, itemWidth),
      onHorizontalDragStart: (details) => _handleDragStart(details, itemWidth),
      onHorizontalDragUpdate: (details) =>
          _handleDragUpdate(details, itemWidth),
      onHorizontalDragEnd: (details) => _handleDragEnd(details, itemWidth),
      onHorizontalDragCancel: _handleDragCancel,
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
    );
  }

  void _handleTapUp(TapUpDetails details, double itemWidth) {
    _pointerDownX = null;
    _pointerDownTime = null;
    _cancelSpring();
    widget.onInteractionStart?.call();
    widget.onTap(_indexForX(details.localPosition.dx, itemWidth));
  }

  void _handleDragStart(DragStartDetails details, double itemWidth) {
    _cancelSpring();
    widget.onInteractionStart?.call();
    final startPosition = _positionForX(
      _pointerDownX ?? details.localPosition.dx,
      itemWidth,
    );
    final initialDelta =
        details.localPosition.dx - (_pointerDownX ?? details.localPosition.dx);
    _controller.beginDrag(startPosition);
    // HorizontalDragStart 在 touch slop 之后才触发；用这段已发生的位移
    // 初始化速度，保证第一次可见拖动就有真实的形变反馈。
    _velocityPixelsPerSecond = initialDelta * 15;
    _lastPointerX = _pointerDownX ?? details.localPosition.dx;
    _lastPointerTime = _pointerDownTime ?? details.sourceTimeStamp;
    setState(() => _isDragging = true);
    _setVisualPosition(startPosition);
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
    _velocityPixelsPerSecond =
        _velocityPixelsPerSecond * 0.75 + instantaneousVelocity * 0.25;
    _lastPointerX = x;
    _lastPointerTime = sourceTime;

    _controller.updateDrag(
      rawPosition: _positionForX(x, itemWidth, allowOverdrag: true),
      velocityPixelsPerSecond: _velocityPixelsPerSecond,
    );
    _setVisualPosition(_controller.position);
  }

  void _handleDragEnd(DragEndDetails details, double itemWidth) {
    if (!_isDragging) return;
    final velocity = details.primaryVelocity ?? _velocityPixelsPerSecond;
    final target = _controller.endDrag(
      velocityPixelsPerSecond: velocity,
      itemWidth: itemWidth,
    );
    _pointerDownX = null;
    _pointerDownTime = null;
    _lastPointerTime = null;
    _settleTo(target, velocity / itemWidth);
  }

  void _handleDragCancel() {
    if (!_isDragging) return;
    _pointerDownX = null;
    _pointerDownTime = null;
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
    if ((widget.visualIndexListenable.value - next).abs() > 0.0001) {
      widget.visualIndexListenable.value = next;
    }
    // 位置被边界 clamp 后仍要重绘 edgeCompression / velocity 形变；不让
    // “手指继续向屏幕边缘拖”因为 position 没变化而丢失视觉反馈。
    _motionFrame.value++;
    widget.onVisualPositionChanged?.call(next);
  }

  int _indexForX(double x, double itemWidth) {
    return ((x / itemWidth) - 0.5).round().clamp(0, _navLabels.length - 1);
  }

  double _positionForX(
    double x,
    double itemWidth, {
    bool allowOverdrag = false,
  }) {
    final raw = x / itemWidth - 0.5;
    if (allowOverdrag) return raw;
    return raw.clamp(0.0, _navLabels.length - 1).toDouble();
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
  });

  final bool isDark;
  final bool highContrast;
  final bool useLiquidGlass;

  @override
  Widget build(BuildContext context) {
    final fill = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: useLiquidGlass
              ? (isDark
                  ? [
                      const Color(0xFF202326).withValues(
                        alpha: highContrast ? 0.44 : 0.36,
                      ),
                      const Color(0xFF111315).withValues(
                        alpha: highContrast ? 0.38 : 0.28,
                      ),
                    ]
                  : [
                      Colors.white.withValues(
                        alpha: highContrast ? 0.36 : 0.26,
                      ),
                      Colors.white.withValues(
                        alpha: highContrast ? 0.27 : 0.18,
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
              ? Colors.white.withValues(alpha: highContrast ? 0.28 : 0.16)
              : (useLiquidGlass
                  ? Colors.white.withValues(alpha: highContrast ? 0.72 : 0.55)
                  : AppColors.borderNormalLight),
          width: highContrast ? 1.25 : 1,
        ),
      ),
    );

    if (!useLiquidGlass) return fill;
    return BackdropFilter(
      filter: ui.ImageFilter.blur(
        sigmaX: isDark ? 8 : 7,
        sigmaY: isDark ? 8 : 7,
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
        debugPrint('[LiquidGlass] renderer=fallback tier=C shader=false');
        return null;
      }
      try {
        final program = await ui.FragmentProgram.fromAsset(
          'shaders/liquid_nav_lens.frag',
        );
        debugPrint('[LiquidGlass] renderer=shader tier=A impeller=unknown');
        return program;
      } catch (error) {
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
    final baseWidth = math.max(84.0, widget.itemWidth * 1.55);
    final lensWidth = baseWidth *
        (1 + speed * 0.18 - widget.edgeCompression.clamp(0.0, 1.0) * 0.10);
    final lensHeight = 58.0 * (1 - speed * 0.06);
    final requestedCenter = widget.itemWidth * (widget.visualIndex + 0.5);
    final lensCenter = requestedCenter.clamp(
      lensWidth / 2 + 2,
      widget.dockSize.width - lensWidth / 2 - 2,
    );
    final left = lensCenter - lensWidth / 2;
    final top = (widget.dockSize.height - lensHeight) / 2;
    final shader = _shader;
    final canRefract = shader != null && ui.ImageFilter.isShaderFilterSupported;

    if (canRefract) {
      shader
        ..setFloat(2, 14.0)
        ..setFloat(3, 1.055)
        ..setFloat(4, 1.2)
        ..setFloat(5, speed)
        ..setFloat(6, direction)
        ..setFloat(7, widget.edgeCompression)
        ..setFloat(8, widget.isDragging ? 1.0 : 0.0)
        ..setFloat(9, 1.0)
        ..setFloat(10, 1.0)
        ..setFloat(11, 1.0)
        ..setFloat(12, widget.isDark ? 0.045 : 0.03)
        ..setFloat(13, widget.highContrast ? 0.42 : 0.34)
        ..setFloat(14, widget.highContrast ? 0.22 : 0.16);
    }

    final filter = canRefract
        ? ui.ImageFilter.shader(shader)
        : ui.ImageFilter.blur(sigmaX: 4, sigmaY: 4);

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
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.pill),
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
  });

  final bool isDark;
  final bool highContrast;
  final double motion;
  final double direction;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(highContrast ? 0.8 : 0.6);
    final rim = RRect.fromRectAndRadius(
      rect,
      Radius.circular(size.height / 2),
    );
    final begin = direction < 0 ? Alignment.topRight : Alignment.topLeft;
    final end = direction < 0 ? Alignment.bottomLeft : Alignment.bottomRight;
    final rimPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = highContrast ? 1.5 : 1.0
      ..shader = LinearGradient(
        begin: begin,
        end: end,
        colors: [
          Colors.white.withValues(alpha: highContrast ? 0.92 : 0.72),
          Colors.white.withValues(alpha: isDark ? 0.30 : 0.18),
          Colors.black.withValues(alpha: isDark ? 0.16 : 0.05),
          Colors.white.withValues(alpha: highContrast ? 0.78 : 0.48),
        ],
      ).createShader(rect);
    canvas.drawRRect(rim, rimPaint);

    final highlightRect = Rect.fromLTWH(
      size.width * 0.16,
      1.2,
      size.width * 0.68,
      math.max(1.0, size.height * 0.32),
    );
    final highlightPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = highContrast ? 1.15 : 0.75
      ..shader = LinearGradient(
        colors: [
          Colors.white.withValues(alpha: 0),
          Colors.white.withValues(
            alpha: (highContrast ? 0.72 : 0.42) + motion * 0.12,
          ),
          Colors.white.withValues(alpha: 0),
        ],
      ).createShader(highlightRect);
    canvas.drawArc(highlightRect, math.pi, math.pi, false, highlightPaint);
  }

  @override
  bool shouldRepaint(covariant _LiquidLensRimPainter oldDelegate) {
    return oldDelegate.isDark != isDark ||
        oldDelegate.highContrast != highContrast ||
        oldDelegate.motion != motion ||
        oldDelegate.direction != direction;
  }
}
