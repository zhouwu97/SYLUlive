import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

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
import 'liquid_glass/interactive_highlight.dart';
import 'liquid_glass/liquid_glass_motion.dart';
import 'liquid_glass/liquid_glass_visual_inertia.dart';
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
// 普通选中态严格占一格，首尾位置不会越出 Dock；进入液态后再连续扩张。
const _selectionIdleWidthScale = 1.0;
const _tabContentPressedScale = 1.20;
const _pressSpring = SpringDescription(
  mass: 1,
  stiffness: 1000,
  damping: 63.2455532,
);
// 点击切换属于高频 Tab 反馈，使用临界阻尼快速落位；拖拽仍使用更有重量
// 的 settle spring，避免为了修点击而削弱 direct manipulation 的手感。
const _tapSettleSpring = SpringDescription(
  mass: 1,
  stiffness: 720,
  damping: 54,
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

LiquidGlassDragDeformation _selectionDragDeformation({
  required double velocityPixelsPerSecond,
  required double normalization,
  double edgeCompression = 0,
}) {
  return liquidGlassDragDeformationFor(
    velocityPixelsPerSecond: velocityPixelsPerSecond,
    normalization: normalization,
    edgeCompression: edgeCompression,
  );
}

double _selectionScaleX({
  required double activation,
  required double velocityPixelsPerSecond,
  required LiquidGlassTuning tuning,
  double edgeCompression = 0,
}) {
  final pressScale = ui.lerpDouble(
    _selectionIdleWidthScale,
    tuning.pressedScale,
    _selectionPressProgress(activation),
  )!;
  final deformation = _selectionDragDeformation(
    velocityPixelsPerSecond: velocityPixelsPerSecond,
    normalization: tuning.velocityNormalization,
    edgeCompression: edgeCompression,
  );
  return pressScale * deformation.horizontalScale;
}

double _selectionScaleY({
  required double activation,
  required double velocityPixelsPerSecond,
  required LiquidGlassTuning tuning,
  double edgeCompression = 0,
}) {
  final pressScale = ui.lerpDouble(
    1.0,
    tuning.pressedScale,
    _selectionPressProgress(activation),
  )!;
  final deformation = _selectionDragDeformation(
    velocityPixelsPerSecond: velocityPixelsPerSecond,
    normalization: tuning.velocityNormalization,
    edgeCompression: edgeCompression,
  );
  return pressScale * deformation.verticalScale;
}

Rect _selectionRectFor({
  required Size dockSize,
  required double itemWidth,
  required double visualIndex,
  required double activation,
  required double velocityPixelsPerSecond,
  required double edgeCompression,
  required bool useLiquidGlass,
  required LiquidGlassTuning tuning,
}) {
  final scaleX = useLiquidGlass
      ? _selectionScaleX(
          activation: activation,
          velocityPixelsPerSecond: velocityPixelsPerSecond,
          edgeCompression: edgeCompression,
          tuning: tuning,
        )
      : 1.0;
  final scaleY = useLiquidGlass
      ? _selectionScaleY(
          activation: activation,
          velocityPixelsPerSecond: velocityPixelsPerSecond,
          edgeCompression: edgeCompression,
          tuning: tuning,
        )
      : 1.0;
  final baseWidth = useLiquidGlass ? itemWidth : 56.0;
  final baseHeight = useLiquidGlass ? _selectionHeight : 48.0;
  final width = baseWidth * scaleX;
  final height = baseHeight * scaleY;
  final centerX = itemWidth * (visualIndex + 0.5);
  return Rect.fromLTWH(
    centerX - width / 2,
    (dockSize.height - height) / 2,
    width,
    height,
  );
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
  final bool showDiagnostics;
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
    this.showDiagnostics = false,
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
  late final AnimationController _highlightPositionController;
  late final AnimationController _highlightOpacityController;
  late final ValueNotifier<int> _motionFrame;
  late final Listenable _visualFrameListenable;

  double _itemWidth = 1;
  double _velocityPixelsPerSecond = 0;
  double _lastPublishedLogicalPosition = 0;
  double _lastPointerX = 0;
  Duration? _lastPointerTime;
  double? _pointerDownX;
  Offset? _pointerDownLocalPosition;
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
  double _surfaceVisualPosition = 0;
  Offset _highlightPosition = Offset.zero;
  Animation<Offset>? _highlightPositionAnimation;
  Timer? _highlightReleaseTimer;
  int? _collapseTargetIndex;

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
    _surfaceVisualPosition = initialPosition;
    _lastPublishedLogicalPosition = initialPosition;
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
    _highlightPositionController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 56),
    )..addListener(_handleHighlightPositionTick);
    _highlightOpacityController = AnimationController(
      vsync: this,
      duration: AppMotion.micro,
      reverseDuration: AppMotion.fast,
    )..addListener(_handleHighlightOpacityTick);
  }

  @override
  void dispose() {
    _springController
      ..removeListener(_handleSpringTick)
      ..dispose();
    _activationController
      ..removeListener(_handleActivationTick)
      ..dispose();
    _highlightPositionController
      ..removeListener(_handleHighlightPositionTick)
      ..dispose();
    _highlightOpacityController
      ..removeListener(_handleHighlightOpacityTick)
      ..dispose();
    _highlightReleaseTimer?.cancel();
    _motionFrame.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final themeProvider = context.watch<ThemeProvider>();
    final intensity = themeProvider.bottomNavAnimationIntensity;
    final tuning = widget.tuning.copyWith(
      pressedScale: ui.lerpDouble(1.0, widget.tuning.pressedScale, intensity)!,
      refraction: widget.tuning.refraction * intensity,
      chromatic: widget.tuning.chromatic * intensity,
      dockRefraction: widget.tuning.dockRefraction * intensity,
      dockChromatic: widget.tuning.dockChromatic * intensity,
    );

    final style = themeProvider.bottomNavStyle;
    if (style != BottomNavStyle.normal) {
      return _buildFloatingNav(
        context,
        isDark,
        style == BottomNavStyle.liquidGlass,
        useShader: themeProvider.bottomNavShaderEnabled,
        tuning: tuning,
      );
    }
    return _buildNormalNav(context, isDark);
  }

  // 普通模式是稳定的实色 surface：不透明、不做 BackdropFilter，适合低端
  // 设备、省电模式和偏好稳定反馈的用户。连续 Lens 只属于悬浮 Dock。
  Widget _buildNormalNav(BuildContext context, bool isDark) {
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
              color: isDark
                  ? AppColors.surfaceSecondaryDark
                  : AppColors.surfaceSecondaryLight,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.18 : 0.06),
                  blurRadius: 10,
                  offset: const Offset(0, -2),
                ),
              ],
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
    required bool useShader,
    required LiquidGlassTuning tuning,
  }) {
    final mediaQuery = MediaQuery.of(context);
    final highContrast = mediaQuery.highContrast;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    const dockHorizontalInset = 12.0;
    const dockBottomInset = 12.0;

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
                    // 父级或测试 harness 也可能直接推进 logical notifier；这类
                    // 外部同步不能被表面滞后吞掉，命中区域和选中窗口要立即对齐。
                    if ((visualIndex - _lastPublishedLogicalPosition).abs() >
                        0.0001) {
                      _lastPublishedLogicalPosition = visualIndex;
                      _surfaceVisualPosition = visualIndex;
                    }
                    final effectiveVisualIndex = reduceMotion && !_isDragging
                        ? widget.currentIndex.toDouble()
                        : visualIndex;
                    final phase = widget.qaPhase ?? _phase;
                    final activation =
                        (widget.qaActivation ?? _activation).clamp(0.0, 1.0);
                    if (phase == LiquidNavPhase.idle && !_isDragging) {
                      _surfaceVisualPosition = effectiveVisualIndex;
                    }
                    final surfaceVisualIndex = clampLiquidGlassSurfacePosition(
                      _surfaceVisualPosition,
                      _navLabels.length,
                    );
                    // QA 的 Dragging 状态没有真实 pointer velocity，使用固定预览值
                    // 让尾部、方向和边缘压缩仍然可被人工检查；生产路径继续读取真实速度。
                    final qaPreviewDragging =
                        widget.qaPhase == LiquidNavPhase.dragging;
                    final previewVelocityPixelsPerSecond = qaPreviewDragging
                        ? tuning.velocityNormalization * 0.72
                        : _velocityPixelsPerSecond;
                    final previewEdgeCompression =
                        qaPreviewDragging ? 0.16 : _controller.edgeCompression;
                    final renderedSurfaceVisualIndex = qaPreviewDragging
                        ? clampLiquidGlassSurfacePosition(
                            liquidGlassSurfaceTargetPosition(
                              logicalPosition: effectiveVisualIndex,
                              velocityPixelsPerSecond:
                                  previewVelocityPixelsPerSecond,
                              itemWidth: itemWidth,
                              dragging: true,
                              reduceMotion: reduceMotion,
                            ),
                            _navLabels.length,
                          )
                        : surfaceVisualIndex;
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
                    final motion = liquidGlassMotionFor(
                      phase: phase,
                      activation: activation.toDouble(),
                      velocityPixelsPerSecond: selectionVelocity,
                      visualPosition: effectiveVisualIndex,
                      currentIndex: widget.currentIndex,
                      edgeCompression: selectionEdgeCompression,
                      reduceMotion: reduceMotion,
                      tuning: tuning,
                    );
                    final selectionRect = _selectionRectFor(
                      dockSize: dockSize,
                      itemWidth: itemWidth,
                      visualIndex: idleSelectionIndex,
                      activation: activation.toDouble(),
                      velocityPixelsPerSecond: selectionVelocity,
                      edgeCompression: selectionEdgeCompression,
                      useLiquidGlass: useLiquidGlass,
                      tuning: tuning,
                    );

                    return Transform.translate(
                      offset: Offset(motion.dockRecoilX, 0),
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          if (useLiquidGlass)
                            _FloatingLiquidSelection(
                              layer: _LiquidSelectionLayer.backdrop,
                              dockSize: dockSize,
                              itemWidth: itemWidth,
                              visualIndex: renderedSurfaceVisualIndex,
                              velocityPixelsPerSecond: selectionVelocity,
                              edgeCompression: selectionEdgeCompression,
                              phase: phase,
                              activation: activation.toDouble(),
                              pressDepth: phase == LiquidNavPhase.idle ? 0 : 1,
                              isDark: isDark,
                              highContrast: highContrast,
                              reduceMotion: reduceMotion,
                              useLiquidGlass: useLiquidGlass,
                              useShader: useShader,
                              tuning: tuning,
                              badges: widget.badges,
                              motion: motion,
                              highlightPosition: _highlightPosition,
                              highlightOpacity:
                                  _highlightOpacityController.value,
                            ),
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
                              child: ClipPath(
                                key: useLiquidGlass
                                    ? const ValueKey(
                                        'bottom-nav-dock-exclusion',
                                      )
                                    : null,
                                clipper: _LiquidSelectionExclusionClipper(
                                  useLiquidGlass ? selectionRect : null,
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
                                          useShader: useShader,
                                          tuning: tuning,
                                          motion: motion,
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
                                                  Colors.white.withValues(
                                                    alpha: 0,
                                                  ),
                                                  Colors.white.withValues(
                                                    alpha: highContrast
                                                        ? 0.28
                                                        : 0.14,
                                                  ),
                                                  Colors.white.withValues(
                                                    alpha: 0,
                                                  ),
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
                          ),
                          Positioned.fill(
                            child: RepaintBoundary(
                              child: _buildGestureLayer(
                                context: context,
                                itemWidth: itemWidth,
                                visualIndex: effectiveVisualIndex,
                                useLiquidGlass: useLiquidGlass,
                                selectionRect: selectionRect,
                              ),
                            ),
                          ),
                          _FloatingLiquidSelection(
                            layer: useLiquidGlass
                                ? _LiquidSelectionLayer.foreground
                                : _LiquidSelectionLayer.backdrop,
                            dockSize: dockSize,
                            itemWidth: itemWidth,
                            visualIndex: renderedSurfaceVisualIndex,
                            velocityPixelsPerSecond: selectionVelocity,
                            edgeCompression: selectionEdgeCompression,
                            phase: phase,
                            activation: activation.toDouble(),
                            pressDepth: phase == LiquidNavPhase.idle ? 0 : 1,
                            isDark: isDark,
                            highContrast: highContrast,
                            reduceMotion: reduceMotion,
                            useLiquidGlass: useLiquidGlass,
                            useShader: useShader,
                            tuning: tuning,
                            badges: widget.badges,
                            motion: motion,
                            highlightPosition: _highlightPosition,
                            highlightOpacity: _highlightOpacityController.value,
                          ),
                          if (widget.showDiagnostics)
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
                                edgeCompression:
                                    phase == LiquidNavPhase.dragging
                                        ? previewEdgeCompression
                                        : 0,
                                itemWidth: itemWidth,
                                tuning: tuning,
                              ),
                            ),
                        ],
                      ),
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
    required bool useLiquidGlass,
    required Rect selectionRect,
  }) {
    final tabs = Row(
      children: List.generate(
        _navLabels.length,
        (index) {
          final icon = _navIcons[index];
          final label = _navLabels[index];
          final showBadge = widget.badges[index] == true;
          return useLiquidGlass
              ? _floatingLiquidItem(
                  icon: icon,
                  label: label,
                  index: index,
                  context: context,
                  width: itemWidth,
                  showBadge: showBadge,
                )
              : _floatingItem(
                  icon: icon,
                  label: label,
                  index: index,
                  context: context,
                  width: itemWidth,
                  visualIndex: visualIndex,
                  showBadge: showBadge,
                );
        },
      ),
    );
    return GestureDetector(
      key: const ValueKey('bottom-nav-gesture-layer'),
      behavior: HitTestBehavior.opaque,
      onTapUp: (details) => _handleTapUp(details, itemWidth, useLiquidGlass),
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: _handlePointerDownEvent,
        onPointerMove: _handlePointerMoveEvent,
        onPointerUp: _handlePointerUpEvent,
        onPointerCancel: _handlePointerCancelEvent,
        child: useLiquidGlass
            ? ClipPath(
                key: const ValueKey('bottom-nav-normal-exclusion'),
                clipper: _LiquidSelectionExclusionClipper(selectionRect),
                child: tabs,
              )
            : tabs,
      ),
    );
  }

  void _handlePointerDownEvent(PointerDownEvent event) {
    // Android Emulator 的 Ctrl 多点模式会生成第二个对称触点；它不能
    // 接管当前 Lens，否则 VelocityTracker 和 grab offset 会被覆盖。
    if (_pointerId != null) return;
    final localPosition = _localPointerPosition(event);
    final localX = localPosition.dx;
    _recordPointerDown(localPosition);
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
    final localPosition = _localPointerPosition(event);
    final localX = localPosition.dx;
    if (_phase == LiquidNavPhase.pressing ||
        _phase == LiquidNavPhase.dragging ||
        _highlightOpacityController.value > 0.001) {
      _setHighlightTarget(localPosition);
    }

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
      _releaseInteractiveHighlight();
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
      _releaseInteractiveHighlight();
      if (shouldCollapse) _startCollapse(widget.currentIndex);
    }
  }

  void _clearActivePointer() {
    _velocityTracker = null;
    _pointerId = null;
  }

  void _clearPointerState() {
    _pointerDownX = null;
    _pointerDownLocalPosition = null;
    _pointerDownTime = null;
    _lastPointerTime = null;
    _pointerInsideIdleSelection = false;
    _pointerInsideActiveLens = false;
    _pointerUpVelocityPixelsPerSecond = null;
    _clearActivePointer();
  }

  void _recordPointerDown(Offset localPosition) {
    final localX = localPosition.dx;
    _pointerDownX = localX;
    _pointerDownLocalPosition = localPosition;
    _pointerInsideIdleSelection = _isPointInsideIdleSelection(localX);
    _pointerInsideActiveLens = _isPointInsideActiveLens(localX);
    _grabOffsetX = localX - _controller.lensCenterX;
  }

  void _handleTapUp(
    TapUpDetails details,
    double itemWidth,
    bool useLiquidGlass,
  ) {
    _clearPointerState();
    final target = _indexForX(details.localPosition.dx, itemWidth);
    if (!useLiquidGlass || target == widget.currentIndex) {
      widget.onTap(target);
      return;
    }
    _startLiquidTapNavigation(target, details.localPosition);
  }

  void _startLiquidTapNavigation(int target, Offset highlightPosition) {
    _cancelSpring();
    _velocityPixelsPerSecond = 0;
    _collapseTargetIndex = null;
    _showInteractiveHighlight(highlightPosition);
    _animateActivationTo(1);
    _commitNavigation(target);
    _settleTo(target, 0, quick: true);
  }

  Offset _localPointerPosition(PointerEvent event) {
    final renderObject = _dockRenderKey.currentContext?.findRenderObject();
    return renderObject is RenderBox
        ? renderObject.globalToLocal(event.position)
        : event.position;
  }

  void _beginPress(double localX) {
    final currentIndex = widget.currentIndex.clamp(0, _navLabels.length - 1);
    _cancelSpring(resetPosition: currentIndex.toDouble());
    _grabOffsetX = localX - _controller.lensCenterX;
    _velocityPixelsPerSecond = 0;
    _collapseTargetIndex = null;
    _setVisualPosition(currentIndex.toDouble());
    _setPhase(LiquidNavPhase.pressing);
    _showInteractiveHighlight(
      _pointerDownLocalPosition ?? Offset(localX, _dockHeight / 2),
    );
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
    _showInteractiveHighlight(
      _highlightPosition == Offset.zero
          ? Offset(localX, _dockHeight / 2)
          : _highlightPosition,
    );
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
    _setHighlightTarget(Offset(x, _highlightPosition.dy));
    _setVisualPosition(_controller.position);
  }

  void _endDrag(double velocity) {
    if (_phase != LiquidNavPhase.dragging) return;
    final target = _controller.endDrag(
      velocityPixelsPerSecond: velocity,
      itemWidth: _itemWidth,
    );
    _clearPointerState();
    _releaseInteractiveHighlight();
    _commitNavigation(target);
    _settleTo(target, velocity / _itemWidth);
  }

  void _handleDragCancel() {
    if (_phase != LiquidNavPhase.dragging) return;
    _clearPointerState();
    _releaseInteractiveHighlight();
    _controller.cancelDrag(widget.currentIndex.toDouble());
    _settleTo(widget.currentIndex, 0);
  }

  void _settleTo(
    int target,
    double initialVelocity, {
    bool quick = false,
  }) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final start = widget.visualIndexListenable.value
        .clamp(0.0, _navLabels.length - 1)
        .toDouble();
    final serial = ++_settleSerial;
    _springController.stop();
    _collapseTargetIndex = target;
    _setPhase(LiquidNavPhase.settling);

    if (reduceMotion || (start - target).abs() < 0.001) {
      _finishSettle(serial, target, quick: quick);
      return;
    }

    _springController.value = start;
    final simulation = SpringSimulation(
      quick
          ? _tapSettleSpring
          : const SpringDescription(mass: 1, stiffness: 320, damping: 24),
      start,
      target.toDouble(),
      initialVelocity,
    );
    unawaited(
      _springController.animateWith(simulation).then<void>((_) {
        _finishSettle(serial, target, quick: quick);
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

  void _finishSettle(
    int serial,
    int target, {
    bool quick = false,
  }) {
    if (!mounted || serial != _settleSerial) return;
    _controller.settle(target.toDouble());
    _velocityPixelsPerSecond = 0;
    _setVisualPosition(target.toDouble());
    if (mounted) _startCollapse(target, quick: quick);
  }

  /// 业务状态先响应，Lens 只负责把视觉位置收敛到已提交的 Tab。
  void _commitNavigation(int target) {
    final onCommitted = widget.onNavigationCommitted;
    if (onCommitted != null) {
      onCommitted(target);
    } else {
      widget.onTap(target);
    }
  }

  void _startCollapse(int target, {bool quick = false}) {
    _collapseTargetIndex = target;
    _setPhase(LiquidNavPhase.collapsing);
    _releaseInteractiveHighlight(quick: quick);
    final reduced = MediaQuery.disableAnimationsOf(context);
    if (reduced) {
      _activationController.value = 0;
      _finishCollapse(target);
      return;
    }
    _animateActivationTo(
      0,
      spring: quick ? _tapSettleSpring : null,
      onComplete: () => _finishCollapse(target),
    );
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

  void _handleHighlightPositionTick() {
    final animation = _highlightPositionAnimation;
    if (animation == null) return;
    _highlightPosition = animation.value;
    _motionFrame.value++;
  }

  void _handleHighlightOpacityTick() {
    _motionFrame.value++;
  }

  void _setHighlightTarget(Offset target) {
    final safeTarget = Offset(
      target.dx.isFinite ? target.dx : _highlightPosition.dx,
      target.dy.isFinite ? target.dy : _highlightPosition.dy,
    );
    if ((safeTarget - _highlightPosition).distanceSquared < 0.01) return;

    final reduced = MediaQuery.disableAnimationsOf(context);
    _highlightPositionController.stop();
    if (reduced) {
      _highlightPosition = safeTarget;
      _motionFrame.value++;
      return;
    }
    _highlightPositionAnimation = Tween<Offset>(
      begin: _highlightPosition,
      end: safeTarget,
    ).animate(
      CurvedAnimation(
        parent: _highlightPositionController,
        curve: Curves.easeOutCubic,
      ),
    );
    _highlightPositionController.forward(from: 0);
  }

  void _showInteractiveHighlight(Offset target) {
    _highlightReleaseTimer?.cancel();
    _setHighlightTarget(target);
    final reduced = MediaQuery.disableAnimationsOf(context);
    if (reduced) {
      _highlightOpacityController.value = 0.72;
      return;
    }
    unawaited(
      _highlightOpacityController
          .animateTo(
            1.0,
            duration: AppMotion.micro,
            curve: Curves.easeOutCubic,
          )
          .catchError((Object _) {}),
    );
  }

  void _releaseInteractiveHighlight({bool quick = false}) {
    _highlightReleaseTimer?.cancel();
    final reduced = MediaQuery.disableAnimationsOf(context);
    if (reduced) {
      _highlightOpacityController.value = 0;
      return;
    }

    void fadeHighlight() {
      if (!mounted) return;
      unawaited(
        _highlightOpacityController
            .animateTo(
              0.0,
              duration: quick ? AppMotion.micro : AppMotion.fast,
              curve: Curves.easeOutCubic,
            )
            .catchError((Object _) {}),
      );
    }

    if (quick) {
      fadeHighlight();
      return;
    }
    _highlightReleaseTimer = Timer(
      const Duration(milliseconds: 52),
      fadeHighlight,
    );
  }

  /// Press progress 使用可中断 spring，Pointer Up / re-grab 都从当前值继续，
  /// 不把选中态拆成“普通 indicator → 另一颗 Lens”。
  void _animateActivationTo(
    double target, {
    VoidCallback? onComplete,
    SpringDescription? spring,
  }) {
    final reduced = MediaQuery.disableAnimationsOf(context);
    _activationController.stop();
    if (reduced) {
      _activationController.value = target;
      onComplete?.call();
      return;
    }

    final simulation = SpringSimulation(
      spring ?? _pressSpring,
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
    if (phase == LiquidNavPhase.idle) {
      _surfaceVisualPosition = widget.visualIndexListenable.value;
    }
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
    _lastPublishedLogicalPosition = next;
    _surfaceVisualPosition = clampLiquidGlassSurfacePosition(
      liquidGlassSurfacePositionFor(
        logicalPosition: next,
        previousPosition: _surfaceVisualPosition,
        velocityPixelsPerSecond: _velocityPixelsPerSecond,
        itemWidth: _itemWidth,
        dragging: _phase == LiquidNavPhase.dragging,
        reduceMotion: MediaQuery.disableAnimationsOf(context),
      ),
      _navLabels.length,
    );
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
    return (x - center).abs() <= _itemWidth * _selectionIdleWidthScale / 2;
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
          edgeCompression: _phase == LiquidNavPhase.dragging
              ? _controller.edgeCompression
              : 0,
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
    return _buildFloatingItemContent(
      icon: icon,
      label: label,
      index: index,
      width: width,
      showBadge: showBadge,
      color: visualState.color,
      scale: visualState.scale,
    );
  }

  /// Liquid Glass 的 Normal Row 是被玻璃观察的底层内容。
  ///
  /// 这里不能读取 visualPosition、activation 或 focusWeight；所有 accent
  /// 变化都由 selection Capsule 内的副本负责，避免普通 Tab 自己变色。
  Widget _floatingLiquidItem({
    required IconData icon,
    required String label,
    required int index,
    required BuildContext context,
    required double width,
    required bool showBadge,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final normalColor =
        isDark ? AppColors.iconMutedDark : AppColors.iconMutedLight;
    return _buildFloatingItemContent(
      icon: icon,
      label: label,
      index: index,
      width: width,
      showBadge: showBadge,
      color: normalColor,
      scale: 1.0,
    );
  }

  Widget _buildFloatingItemContent({
    required IconData icon,
    required String label,
    required int index,
    required double width,
    required bool showBadge,
    required Color color,
    required double scale,
  }) {
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
            key: ValueKey('bottom-nav-normal-content-$index'),
            scale: scale,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Icon(icon, color: color, size: 24),
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
                    color: color,
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

Future<ui.FragmentProgram?>? _liquidGlassProgramFuture;

Future<ui.FragmentProgram?> _loadLiquidGlassProgram() {
  return _liquidGlassProgramFuture ??= () async {
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

Future<ui.FragmentProgram?>? _liquidGlassDockProgramFuture;

Future<ui.FragmentProgram?> _loadLiquidGlassDockProgram() {
  return _liquidGlassDockProgramFuture ??= () async {
    if (!ui.ImageFilter.isShaderFilterSupported) return null;
    try {
      return await ui.FragmentProgram.fromAsset(
        'shaders/liquid_nav_dock.frag',
      );
    } catch (error) {
      debugPrint('[LiquidGlass] dock shader load failed: $error');
      return null;
    }
  }();
}

class _FloatingDockSurface extends StatefulWidget {
  const _FloatingDockSurface({
    required this.isDark,
    required this.highContrast,
    required this.useLiquidGlass,
    required this.useShader,
    required this.tuning,
    required this.motion,
  });

  final bool isDark;
  final bool highContrast;
  final bool useLiquidGlass;
  final bool useShader;
  final LiquidGlassTuning tuning;
  final LiquidGlassMotionState motion;

  @override
  State<_FloatingDockSurface> createState() => _FloatingDockSurfaceState();
}

class _FloatingDockSurfaceState extends State<_FloatingDockSurface> {
  ui.FragmentShader? _shader;

  @override
  void initState() {
    super.initState();
    if (widget.useLiquidGlass && widget.useShader) _loadShader();
  }

  @override
  void didUpdateWidget(covariant _FloatingDockSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.useLiquidGlass &&
        widget.useShader &&
        (!oldWidget.useLiquidGlass || !oldWidget.useShader) &&
        _shader == null) {
      _loadShader();
    }
  }

  Future<void> _loadShader() async {
    final program = await _loadLiquidGlassDockProgram();
    if (!mounted || program == null || _shader != null) return;
    setState(() => _shader = program.fragmentShader());
  }

  @override
  void dispose() {
    _shader?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dockAlpha = widget.tuning.dockAlpha.clamp(0.0, 1.0).toDouble();
    final surfaceColor = widget.useLiquidGlass
        ? (widget.isDark ? const Color(0xFF121212) : const Color(0xFFFAFAFA))
        : (widget.isDark
            ? AppColors.surfaceSecondaryDark
            : AppColors.surfaceSecondaryLight);
    final surfaceAlpha =
        widget.highContrast ? math.min(1.0, dockAlpha + 0.10) : dockAlpha;
    final fill = DecoratedBox(
      decoration: BoxDecoration(
        color: surfaceColor.withValues(
          alpha: widget.useLiquidGlass ? surfaceAlpha : 1.0,
        ),
        border: Border.all(
          color: widget.isDark
              ? Colors.white.withValues(
                  alpha: widget.highContrast ? 0.30 : 0.14,
                )
              : (widget.useLiquidGlass
                  ? Colors.white.withValues(
                      alpha: widget.highContrast ? 0.66 : 0.30,
                    )
                  : AppColors.borderNormalLight),
          width: widget.highContrast ? 1.25 : 1,
        ),
      ),
    );

    if (!widget.useLiquidGlass) return fill;

    return LayoutBuilder(
      builder: (context, constraints) {
        final blur = widget.tuning.dockBlur.clamp(0.0, 24.0).toDouble();
        final shader = _shader;
        final canRefract = widget.useShader &&
            shader != null &&
            ui.ImageFilter.isShaderFilterSupported &&
            widget.motion.opticalActivation > 0.0001;
        if (canRefract) {
          LiquidGlassDockShaderUniforms(
            logicalSize: constraints.biggest,
            dockSize: constraints.biggest,
            refraction: widget.motion.dockRefraction,
            chromatic: widget.motion.dockChromatic,
            refractionHeight: widget.tuning.dockRefractionHeight,
            activation: widget.motion.opticalActivation,
          ).apply(shader);
        }
        final backdropFilter = canRefract
            ? ui.ImageFilter.compose(
                outer: ui.ImageFilter.shader(shader),
                inner: ui.ImageFilter.blur(
                  sigmaX: widget.isDark ? blur + 1 : blur,
                  sigmaY: widget.isDark ? blur + 1 : blur,
                ),
              )
            : ui.ImageFilter.blur(
                sigmaX: widget.isDark ? blur + 1 : blur,
                sigmaY: widget.isDark ? blur + 1 : blur,
              );

        return Stack(
          fit: StackFit.expand,
          clipBehavior: Clip.none,
          children: [
            ColorFiltered(
              colorFilter: ColorFilter.matrix(
                _vibrancyMatrix(
                  saturation: widget.tuning.dockSaturation,
                  contrast: widget.tuning.dockContrast,
                ),
              ),
              child: BackdropFilter(
                filter: backdropFilter,
                child: const SizedBox.expand(),
              ),
            ),
            Positioned.fill(child: fill),
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: LiquidGlassDockSpecularPainter(
                    progress: widget.motion.opticalActivation,
                    strength: widget.tuning.dockSpecularStrength,
                    highContrast: widget.highContrast,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

List<double> _vibrancyMatrix({
  required double saturation,
  required double contrast,
}) {
  const r = 0.2126;
  const g = 0.7152;
  const b = 0.0722;
  final inv = 1 - saturation;
  final cr = r * inv;
  final cg = g * inv;
  final cb = b * inv;
  final offset = 0.5 * (1 - contrast);
  return <double>[
    (cr + saturation) * contrast,
    cg * contrast,
    cb * contrast,
    0,
    offset,
    cr * contrast,
    (cg + saturation) * contrast,
    cb * contrast,
    0,
    offset,
    cr * contrast,
    cg * contrast,
    (cb + saturation) * contrast,
    0,
    offset,
    0,
    0,
    0,
    1,
    0,
  ];
}

class _AccentTabsContent extends StatelessWidget {
  const _AccentTabsContent({
    required this.itemWidth,
    required this.activation,
    required this.color,
    required this.badges,
  });

  final double itemWidth;
  final double activation;
  final Color color;
  final Map<int, bool> badges;

  @override
  Widget build(BuildContext context) {
    // 交互反馈以 Lens 位移为主，内容只做极轻的 icon 反馈；避免图标、文字、
    // blur 和 shader 同时放大，形成演示 Demo 式的“全都在动”。
    final iconScale = ui.lerpDouble(
      1.0,
      1.04,
      activation.clamp(0.0, 1.0).toDouble(),
    )!;
    return ExcludeSemantics(
      child: Row(
        children: List.generate(
          _navLabels.length,
          (index) => SizedBox(
            width: itemWidth,
            height: _dockHeight,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Transform.scale(
                  key: ValueKey('bottom-nav-accent-content-scale-$index'),
                  scale: iconScale,
                  child: Stack(
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
        ),
      ),
    );
  }
}

/// Normal Row 只在胶囊之外可见。胶囊内部由独立 Accent Row 绘制，避免
/// BackdropFilter 再次采样普通 Tab 后形成双图标和文字重影。
class _LiquidSelectionExclusionClipper extends CustomClipper<Path> {
  const _LiquidSelectionExclusionClipper(this.selectionRect);

  final Rect? selectionRect;

  @override
  Path getClip(Size size) {
    final path = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size);
    final rect = selectionRect;
    if (rect != null) {
      path.addRRect(
        RRect.fromRectAndRadius(
          rect,
          Radius.circular(rect.shortestSide / 2),
        ),
      );
    }
    return path;
  }

  @override
  bool shouldReclip(covariant _LiquidSelectionExclusionClipper oldClipper) =>
      oldClipper.selectionRect != selectionRect;
}

enum _LiquidSelectionLayer { backdrop, foreground }

class _FloatingLiquidSelection extends StatefulWidget {
  const _FloatingLiquidSelection({
    required this.layer,
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
    required this.useLiquidGlass,
    required this.useShader,
    required this.tuning,
    required this.badges,
    required this.motion,
    required this.highlightPosition,
    required this.highlightOpacity,
  });

  final _LiquidSelectionLayer layer;
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
  final bool useLiquidGlass;
  final bool useShader;
  final LiquidGlassTuning tuning;
  final Map<int, bool> badges;
  final LiquidGlassMotionState motion;
  final Offset highlightPosition;
  final double highlightOpacity;

  @override
  State<_FloatingLiquidSelection> createState() =>
      _FloatingLiquidSelectionState();
}

class _FloatingLiquidSelectionState extends State<_FloatingLiquidSelection> {
  ui.FragmentShader? _shader;

  @override
  void initState() {
    super.initState();
    if (widget.layer == _LiquidSelectionLayer.backdrop && widget.useShader) {
      _loadShader();
    }
  }

  Future<void> _loadShader() async {
    final program = await _loadLiquidGlassProgram();
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
    final progress = widget.activation.clamp(0.0, 1.0).toDouble();
    // Idle 只保留 frosted surface；press/drag/settling/collapsing 才通过同一颗
    // Lens 打开折射，避免没有交互时持续显示液态边缘。
    final opticalProgress = widget.motion.opticalActivation;
    final hasOpticalMaterial = widget.useLiquidGlass &&
        widget.useShader &&
        opticalProgress > 0.0001 &&
        (widget.tuning.effectiveRefractionHeight > 0 &&
                (widget.motion.refraction.abs() > 0.0001 ||
                    widget.motion.chromatic.abs() > 0.0001) ||
            widget.tuning.effectiveLightStrength > 0 ||
            widget.tuning.effectiveRimStrength > 0 ||
            widget.tuning.mode == LiquidGlassQaMode.shapeOnly);
    final speed = widget.motion.speed;
    final direction = widget.motion.direction;
    // 背景光学层、Normal Row 挖空与 Accent 前景必须共享同一几何。
    final selectionRect = _selectionRectFor(
      dockSize: widget.dockSize,
      itemWidth: widget.itemWidth,
      visualIndex: widget.visualIndex,
      activation: progress,
      velocityPixelsPerSecond: widget.velocityPixelsPerSecond,
      edgeCompression: widget.edgeCompression,
      useLiquidGlass: widget.useLiquidGlass,
      tuning: widget.tuning,
    );
    final left = selectionRect.left;
    final top = selectionRect.top;
    final lensWidth = selectionRect.width;
    final lensHeight = selectionRect.height;
    final visibleSize = Size(lensWidth, lensHeight);
    // Selection 也位于 ClipRRect 内，滤镜输入必须与可见胶囊同源同尺寸。
    // 扩展 capture 会被祖先裁剪，却仍以扩展尺寸计算 UV，造成蓝色斜纹/竖条。
    const overscanX = 0.0;
    const overscanY = 0.0;
    final captureSize = visibleSize;
    final captureLensCenter = Offset(lensWidth / 2, lensHeight / 2);
    final shader = _shader;
    final canRefract = widget.useShader &&
        hasOpticalMaterial &&
        shader != null &&
        ui.ImageFilter.isShaderFilterSupported;

    if (canRefract) {
      LiquidGlassShaderUniforms(
        captureSize: captureSize,
        lensCenter: captureLensCenter,
        lensSize: visibleSize,
        lensExponent: widget.tuning.lensExponent,
        refraction: widget.motion.refraction,
        magnification: widget.tuning.effectiveMagnification,
        chromatic: widget.motion.chromatic,
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
        // 折射带始终贴着完整 8px 边缘；只衰减位移强度，不缩窄边缘。
        refractionBandPeak: widget.tuning.effectiveRefractionHeight,
        refractionBandEnd: widget.tuning.refractionBandEnd,
        magnificationRadius: widget.tuning.magnificationRadius,
        chromaticStart: widget.tuning.chromaticStart,
        flowStrength: widget.tuning.flowStrength,
        activation: opticalProgress,
        pressDepth: widget.pressDepth,
      ).apply(shader);
    }

    final lensRadius =
        BorderRadius.circular(math.min(lensWidth, lensHeight) / 2);
    if (widget.layer == _LiquidSelectionLayer.foreground) {
      return Positioned(
        key: const ValueKey('bottom-nav-selection-foreground'),
        left: left,
        top: top,
        width: lensWidth,
        height: lensHeight,
        child: IgnorePointer(
          child: Stack(
            clipBehavior: Clip.none,
            fit: StackFit.expand,
            children: [
              if (hasOpticalMaterial)
                CustomPaint(
                  key: const ValueKey('bottom-nav-selection-edge-halo'),
                  painter: _LiquidLensHaloPainter(
                    highContrast: widget.highContrast,
                    progress: opticalProgress,
                    lightCenter: Offset(
                      widget.highlightPosition == Offset.zero
                          ? lensWidth * 0.28
                          : widget.highlightPosition.dx - left,
                      widget.highlightPosition == Offset.zero
                          ? lensHeight * 0.24
                          : widget.highlightPosition.dy - top,
                    ),
                    lightProgress: widget.highlightOpacity,
                    speed: speed,
                    direction: direction,
                    showShapeOutline:
                        widget.tuning.mode == LiquidGlassQaMode.shapeOnly,
                  ),
                ),
              DecoratedBox(
                key: const ValueKey('bottom-nav-selection-material'),
                decoration: BoxDecoration(
                  borderRadius: lensRadius,
                  border: hasOpticalMaterial
                      ? null
                      : Border.all(
                          color: Colors.white.withValues(
                            alpha: widget.highContrast ? 0.42 : 0.16,
                          ),
                          width: widget.highContrast ? 1.1 : 0.8,
                        ),
                ),
                child: ClipRRect(
                  borderRadius: lensRadius,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Positioned.fill(
                        key: const ValueKey('bottom-nav-accent-tabs'),
                        child: OverflowBox(
                          alignment: Alignment.topLeft,
                          minWidth: widget.dockSize.width,
                          maxWidth: widget.dockSize.width,
                          minHeight: widget.dockSize.height,
                          maxHeight: widget.dockSize.height,
                          child: Transform.translate(
                            offset: Offset(-left, -top),
                            child: SizedBox(
                              width: widget.dockSize.width,
                              height: widget.dockSize.height,
                              child: _AccentTabsContent(
                                itemWidth: widget.itemWidth,
                                activation: progress,
                                color:
                                    widget.tuning.focusColorFor(widget.isDark),
                                badges: widget.badges,
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (hasOpticalMaterial)
                        CustomPaint(
                          painter: _LiquidLensRimPainter(
                            highContrast: widget.highContrast,
                            progress: opticalProgress,
                            showShapeOutline: widget.tuning.mode ==
                                LiquidGlassQaMode.shapeOnly,
                          ),
                        ),
                      if (widget.highlightOpacity > 0.0001)
                        Positioned.fill(
                          child: CustomPaint(
                            key: const ValueKey(
                              'bottom-nav-selection-interactive-highlight',
                            ),
                            painter: LiquidGlassInteractiveHighlightPainter(
                              center: Offset(
                                widget.highlightPosition.dx - left,
                                widget.highlightPosition.dy - top,
                              ),
                              progress: widget.highlightOpacity,
                              radiusScale: widget.tuning.highlightRadius,
                              strength: widget.tuning.highlightStrength,
                              highContrast: widget.highContrast,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final selectionDecoration = widget.useLiquidGlass
        ? BoxDecoration(borderRadius: lensRadius)
        : BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: widget.isDark
                  ? [
                      AppColors.brandPrimary.withValues(alpha: 0.28),
                      AppColors.brandPrimary.withValues(alpha: 0.12),
                    ]
                  : [
                      const Color(0xFFF3FBF8),
                      const Color(0xFFE5F5F0),
                    ],
            ),
            borderRadius: lensRadius,
            border: Border.all(
              color: AppColors.brandPrimary.withValues(
                alpha: widget.isDark ? 0.30 : 0.14,
              ),
            ),
          );

    return Positioned(
      key: const ValueKey('bottom-nav-selection'),
      left: left,
      top: top,
      width: lensWidth,
      height: lensHeight,
      child: IgnorePointer(
        child: DecoratedBox(
          key: const ValueKey('bottom-nav-selection-backdrop'),
          decoration: selectionDecoration,
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
                    // Idle 也是毛玻璃：selection 仍需独立 blur，但只有 active
                    // optical material 才把 FragmentShader 叠加到这层 BackdropFilter。
                    if (widget.useLiquidGlass)
                      Positioned.fill(
                        key: const ValueKey(
                          'bottom-nav-selection-base-blur',
                        ),
                        child: ColorFiltered(
                          colorFilter: ColorFilter.matrix(
                            _vibrancyMatrix(saturation: 1.08, contrast: 1.02),
                          ),
                          child: BackdropFilter(
                            filter: canRefract
                                ? ui.ImageFilter.compose(
                                    outer: ui.ImageFilter.shader(shader),
                                    inner: ui.ImageFilter.blur(
                                      sigmaX: 8,
                                      sigmaY: 8,
                                    ),
                                  )
                                : ui.ImageFilter.blur(
                                    sigmaX: 8,
                                    sigmaY: 8,
                                  ),
                            child: const SizedBox.expand(),
                          ),
                        ),
                      ),
                    if (widget.useLiquidGlass)
                      Positioned.fill(
                        key: const ValueKey(
                          'bottom-nav-selection-base-surface',
                        ),
                        child: ColoredBox(
                          color: (widget.isDark
                                  ? const Color(0xFF26302F)
                                  : const Color(0xFFF0F2EF))
                              .withValues(
                            alpha: ui.lerpDouble(
                              widget.tuning.lensSurfaceAlpha,
                              widget.tuning.lensPressedSurfaceAlpha,
                              progress,
                            )!,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (widget.tuning.showCaptureBounds)
                Positioned.fill(
                  child: CustomPaint(
                    painter: _LiquidLensBoundsPainter(
                      visibleOffset: const Offset(overscanX, overscanY),
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

class _LiquidLensHaloPainter extends CustomPainter {
  const _LiquidLensHaloPainter({
    required this.highContrast,
    required this.progress,
    required this.lightCenter,
    required this.lightProgress,
    required this.speed,
    required this.direction,
    required this.showShapeOutline,
  });

  final bool highContrast;
  final double progress;
  final Offset lightCenter;
  final double lightProgress;
  final double speed;
  final double direction;
  final bool showShapeOutline;

  @override
  void paint(Canvas canvas, Size size) {
    if (showShapeOutline || size.isEmpty) return;

    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(
      rect,
      Radius.circular(math.min(size.width, size.height) / 2),
    );

    final opticalProgress = progress.clamp(0.0, 1.0).toDouble();
    final safeLightCenter = Offset(
      lightCenter.dx.clamp(0.0, size.width).toDouble(),
      lightCenter.dy.clamp(0.0, size.height).toDouble(),
    );
    final lightAngle = math.atan2(
          safeLightCenter.dy - size.height / 2,
          safeLightCenter.dx - size.width / 2,
        ) +
        direction * speed * 0.30;

    // 选中 Lens 的色散由 shader 限制在最外侧边缘；这里仅画中性白色
    // 厚度和一个左上入射 specular，避免绘制第二套彩色玻璃模型。
    final edgeStrokeWidth = highContrast ? 3.2 : 2.4 + opticalProgress * 0.5;
    final edgeAlpha = highContrast ? 0.42 : 0.16 + opticalProgress * 0.10;
    final edgePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = edgeStrokeWidth
      ..strokeCap = StrokeCap.round
      ..blendMode = BlendMode.screen
      ..color = Colors.white.withValues(alpha: edgeAlpha)
      ..maskFilter = MaskFilter.blur(
        BlurStyle.normal,
        highContrast ? 1.4 : 1.8,
      );
    canvas.drawRRect(rrect.deflate(edgeStrokeWidth / 2 + 0.25), edgePaint);

    final specularCenter = Offset(
      size.width * 0.25 + math.cos(lightAngle) * speed * 1.5,
      size.height * 0.16 + math.sin(lightAngle) * speed * 0.5,
    );
    final specularRect = Rect.fromCenter(
      center: specularCenter,
      width: size.width * 0.38,
      height: math.max(2.0, size.height * 0.065),
    );
    final specularPaint = Paint()
      ..blendMode = BlendMode.screen
      ..shader = LinearGradient(
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
        colors: [
          Colors.transparent,
          Colors.white.withValues(alpha: edgeAlpha * 0.72),
          Colors.white.withValues(alpha: edgeAlpha * 0.18),
          Colors.transparent,
        ],
        stops: const [0.0, 0.34, 0.66, 1.0],
      ).createShader(specularRect)
      ..maskFilter =
          MaskFilter.blur(BlurStyle.normal, highContrast ? 1.0 : 1.4);
    canvas.drawOval(specularRect, specularPaint);
  }

  @override
  bool shouldRepaint(covariant _LiquidLensHaloPainter oldDelegate) {
    return oldDelegate.highContrast != highContrast ||
        oldDelegate.progress != progress ||
        oldDelegate.lightCenter != lightCenter ||
        oldDelegate.lightProgress != lightProgress ||
        oldDelegate.speed != speed ||
        oldDelegate.direction != direction ||
        oldDelegate.showShapeOutline != showShapeOutline;
  }
}

class _LiquidLensRimPainter extends CustomPainter {
  const _LiquidLensRimPainter({
    required this.highContrast,
    required this.progress,
    required this.showShapeOutline,
  });

  final bool highContrast;
  final double progress;
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

    // 高光只存在于内侧边缘，不使用 BoxShadow 向四周扩散。
    final innerGlow = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = highContrast ? 5.8 : 4.4
      ..color = Colors.white.withValues(
        alpha: highContrast ? 0.30 : 0.07 + 0.10 * progress,
      )
      ..maskFilter = const MaskFilter.blur(BlurStyle.inner, 1.2);
    canvas.drawRRect(rrect.deflate(0.8), innerGlow);

    final refractiveRim = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = highContrast ? 1.7 : 1.2
      ..strokeCap = StrokeCap.round
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Colors.white.withValues(
            alpha: highContrast ? 0.78 : 0.34 + 0.14 * progress,
          ),
          Colors.white.withValues(
            alpha: highContrast ? 0.28 : 0.10 + 0.06 * progress,
          ),
          Colors.transparent,
          Colors.white.withValues(
            alpha: highContrast ? 0.46 : 0.18 + 0.08 * progress,
          ),
        ],
        stops: const [0, 0.28, 0.66, 1],
      ).createShader(rect);
    canvas.drawRRect(
      rrect.deflate(refractiveRim.strokeWidth / 2),
      refractiveRim,
    );

    // 低透明内侧界线让白色页面上仍能读出折射带的厚度；它不延伸到中心。
    final innerBoundary = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = highContrast ? 1.1 : 0.8
      ..color = Colors.black.withValues(
        alpha: highContrast ? 0.14 : 0.045 + 0.035 * progress,
      )
      ..maskFilter = const MaskFilter.blur(BlurStyle.inner, 0.8);
    canvas.drawRRect(rrect.deflate(3.0), innerBoundary);
  }

  @override
  bool shouldRepaint(covariant _LiquidLensRimPainter oldDelegate) {
    return oldDelegate.highContrast != highContrast ||
        oldDelegate.progress != progress ||
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

/// 仅由显式 QA 入口开启的渲染诊断。它故意放在 Dock 外部，避免把诊断文字
/// 混进 Lens 的采样纹理，也不会拦截手势。
class _LiquidGlassDiagnosticsOverlay extends StatelessWidget {
  const _LiquidGlassDiagnosticsOverlay({
    required this.visualPosition,
    required this.motionFrame,
    required this.isDragging,
    required this.phase,
    required this.activation,
    required this.velocityPixelsPerSecond,
    required this.edgeCompression,
    required this.itemWidth,
    required this.tuning,
  });

  final ValueNotifier<double> visualPosition;
  final ValueNotifier<int> motionFrame;
  final bool isDragging;
  final LiquidNavPhase phase;
  final double activation;
  final double velocityPixelsPerSecond;
  final double edgeCompression;
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
                edgeCompression:
                    phase == LiquidNavPhase.dragging ? edgeCompression : 0,
                tuning: tuning,
              );
          final lensHeight = _selectionHeight *
              _selectionScaleY(
                activation: activation,
                velocityPixelsPerSecond: phase == LiquidNavPhase.dragging
                    ? velocityPixelsPerSecond
                    : 0,
                edgeCompression:
                    phase == LiquidNavPhase.dragging ? edgeCompression : 0,
                tuning: tuning,
              );
          final overscanX = tuning.overscanXFor(lensWidth);
          final overscanY = tuning.overscanYFor(lensHeight);
          final maxOffsetX = tuning.maxSampleOffsetXFor(lensWidth);
          final maxOffsetY = tuning.maxSampleOffsetYFor(lensHeight);
          return DecoratedBox(
            key: const ValueKey('bottom-nav-liquid-diagnostics'),
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
