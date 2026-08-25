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
import 'liquid_glass/liquid_glass_highlight.dart';
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
const _scaleXSpring = SpringDescription(
  mass: 1,
  stiffness: 250,
  damping: 18.97,
);
const _scaleYSpring = SpringDescription(
  mass: 1,
  stiffness: 250,
  damping: 22.14,
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
  required double velocityPixelsPerSecond,
  required LiquidGlassTuning tuning,
  required double springScale,
  double edgeCompression = 0,
}) {
  final deformation = _selectionDragDeformation(
    velocityPixelsPerSecond: velocityPixelsPerSecond,
    normalization: tuning.velocityNormalization,
    edgeCompression: edgeCompression,
  );
  return springScale * deformation.horizontalScale;
}

double _selectionScaleY({
  required double velocityPixelsPerSecond,
  required LiquidGlassTuning tuning,
  required double springScale,
  double edgeCompression = 0,
}) {
  final deformation = _selectionDragDeformation(
    velocityPixelsPerSecond: velocityPixelsPerSecond,
    normalization: tuning.velocityNormalization,
    edgeCompression: edgeCompression,
  );
  return springScale * deformation.verticalScale;
}

Rect _selectionRectFor({
  required Size dockSize,
  required double itemWidth,
  required double visualIndex,
  required int currentIndex,
  required double velocityPixelsPerSecond,
  required double edgeCompression,
  required bool useLiquidGlass,
  required LiquidGlassTuning tuning,
  double springScaleX = _selectionIdleWidthScale,
  double springScaleY = 1.0,
}) {
  if (useLiquidGlass && tuning.isOldV1) {
    final remaining = (currentIndex - visualIndex).abs().clamp(0.0, 1.0);
    final baseWidth = math.max(84.0, itemWidth * 1.30);
    final lensWidth = baseWidth * (1 + remaining * 0.12);
    final lensHeight = 58.0 - remaining * 2;
    final requestedCenter = itemWidth * (visualIndex + 0.5);
    final lensCenter = requestedCenter.clamp(
      lensWidth / 2 + 2,
      dockSize.width - lensWidth / 2 - 2,
    );
    return Rect.fromLTWH(
      lensCenter - lensWidth / 2,
      (dockSize.height - lensHeight) / 2,
      lensWidth,
      lensHeight,
    );
  }

  final scaleX = useLiquidGlass
      ? _selectionScaleX(
          velocityPixelsPerSecond: velocityPixelsPerSecond,
          edgeCompression: edgeCompression,
          tuning: tuning,
          springScale: springScaleX,
        )
      : 1.0;
  final scaleY = useLiquidGlass
      ? _selectionScaleY(
          velocityPixelsPerSecond: velocityPixelsPerSecond,
          edgeCompression: edgeCompression,
          tuning: tuning,
          springScale: springScaleY,
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
  late final AnimationController _scaleXController;
  late final AnimationController _scaleYController;
  late final AnimationController _activationController;
  late final AnimationController _highlightPositionController;
  late final AnimationController _highlightOpacityController;
  late final ValueNotifier<int> _motionFrame;
  late final Listenable _visualFrameListenable;

  double _itemWidth = 1;
  double _velocityPixelsPerSecond = 0;
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
    _motionFrame = ValueNotifier(0);
    _visualFrameListenable = Listenable.merge([
      widget.visualIndexListenable,
      _motionFrame,
    ]);
    _springController = AnimationController.unbounded(
      vsync: this,
      value: initialPosition,
    )..addListener(_handleSpringTick);
    _scaleXController = AnimationController.unbounded(
      vsync: this,
      value: 1.0,
    )..addListener(_handleScaleTick);
    _scaleYController = AnimationController.unbounded(
      vsync: this,
      value: 1.0,
    )..addListener(_handleScaleTick);
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
  void didUpdateWidget(covariant BottomNavWrapper oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.qaPhase != widget.qaPhase ||
        oldWidget.qaActivation != widget.qaActivation) {
      _syncSelectionScaleWithPhase();
    }
  }

  @override
  void dispose() {
    _springController
      ..removeListener(_handleSpringTick)
      ..dispose();
    _scaleXController
      ..removeListener(_handleScaleTick)
      ..dispose();
    _scaleYController
      ..removeListener(_handleScaleTick)
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
    final oldV1 = tuning.isOldV1;
    final dockBottomInset = oldV1 ? 8.0 : 12.0;
    final dockShadows = oldV1
        ? <BoxShadow>[
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.28 : 0.10),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
            if (useLiquidGlass)
              BoxShadow(
                color: AppColors.brandPrimary.withValues(
                  alpha: isDark ? 0.12 : 0.08,
                ),
                blurRadius: 18,
                spreadRadius: -4,
              ),
          ]
        : <BoxShadow>[
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.24 : 0.09),
              blurRadius: useLiquidGlass ? 18 : 16,
              offset: const Offset(0, 7),
            ),
          ];

    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
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
                    // QA 的 Dragging 状态没有真实 pointer velocity，使用固定预览值
                    // 让尾部、方向和边缘压缩仍然可被人工检查；生产路径继续读取真实速度。
                    final qaPreviewDragging =
                        widget.qaPhase == LiquidNavPhase.dragging;
                    final previewVelocityPixelsPerSecond = qaPreviewDragging
                        ? tuning.velocityNormalization * 0.72
                        : _velocityPixelsPerSecond;
                    final previewEdgeCompression =
                        qaPreviewDragging ? 0.16 : _controller.edgeCompression;
                    final renderedSurfaceVisualIndex = effectiveVisualIndex;
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
                      useLiquidGlass: useLiquidGlass,
                    );
                    final selectionRect = _selectionRectFor(
                      dockSize: dockSize,
                      itemWidth: itemWidth,
                      visualIndex: idleSelectionIndex,
                      currentIndex: widget.currentIndex,
                      velocityPixelsPerSecond: selectionVelocity,
                      edgeCompression: selectionEdgeCompression,
                      useLiquidGlass: useLiquidGlass,
                      tuning: tuning,
                      springScaleX: _scaleXController.value,
                      springScaleY: _scaleYController.value,
                    );

                    return Transform.translate(
                      offset: Offset(motion.dockRecoilX, 0),
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          if (useLiquidGlass && !oldV1)
                            _FloatingLiquidSelection(
                              layer: _LiquidSelectionLayer.backdrop,
                              dockSize: dockSize,
                              itemWidth: itemWidth,
                              visualIndex: renderedSurfaceVisualIndex,
                              currentIndex: widget.currentIndex,
                              screenSize: mediaQuery.size,
                              dockGlobalOffset: Offset(
                                mediaQuery.padding.left + dockHorizontalInset,
                                mediaQuery.size.height -
                                    math.max(
                                      mediaQuery.padding.bottom,
                                      mediaQuery.viewInsets.bottom,
                                    ) -
                                    dockBottomInset -
                                    _dockHeight,
                              ),
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
                              springScaleX: _scaleXController.value,
                              springScaleY: _scaleYController.value,
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
                                boxShadow: dockShadows,
                              ),
                              child: ClipPath(
                                key: useLiquidGlass && !oldV1
                                    ? const ValueKey(
                                        'bottom-nav-dock-exclusion',
                                      )
                                    : null,
                                clipper: _LiquidSelectionExclusionClipper(
                                  useLiquidGlass && !oldV1
                                      ? selectionRect
                                      : null,
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
                                                    alpha: oldV1
                                                        ? (highContrast
                                                            ? 0.75
                                                            : 0.52)
                                                        : (highContrast
                                                            ? 0.28
                                                            : 0.14),
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
                                oldV1: oldV1,
                                excludeSelection: useLiquidGlass && !oldV1,
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
                            currentIndex: widget.currentIndex,
                            screenSize: mediaQuery.size,
                            dockGlobalOffset: Offset(
                              mediaQuery.padding.left + dockHorizontalInset,
                              mediaQuery.size.height -
                                  math.max(
                                    mediaQuery.padding.bottom,
                                    mediaQuery.viewInsets.bottom,
                                  ) -
                                  dockBottomInset -
                                  _dockHeight,
                            ),
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
                            springScaleX: _scaleXController.value,
                            springScaleY: _scaleYController.value,
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
    required bool oldV1,
    required bool excludeSelection,
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
                  visualIndex: visualIndex,
                  showBadge: showBadge,
                  oldV1: oldV1,
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
        child: excludeSelection
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

  void _handleScaleTick() {
    if (!mounted) return;
    _motionFrame.value++;
  }

  void _syncSelectionScaleWithPhase() {
    if (!mounted) return;
    final phase = widget.qaPhase ?? _phase;
    final activation =
        (widget.qaActivation ?? _activation).clamp(0.0, 1.0).toDouble();
    final active = switch (phase) {
      LiquidNavPhase.idle => activation > 0.0001,
      LiquidNavPhase.pressing => true,
      LiquidNavPhase.dragging => true,
      LiquidNavPhase.settling => true,
      LiquidNavPhase.collapsing => activation > 0.0001,
    };
    _animateSelectionScaleTo(active ? widget.tuning.pressedScale : 1.0);
  }

  void _animateSelectionScaleTo(double target) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    _scaleXController.stop();
    _scaleYController.stop();
    if (reduceMotion) {
      _scaleXController.value = target;
      _scaleYController.value = target;
      return;
    }

    final xSimulation = SpringSimulation(
      _scaleXSpring,
      _scaleXController.value,
      target,
      _scaleXController.velocity,
    );
    final ySimulation = SpringSimulation(
      _scaleYSpring,
      _scaleYController.value,
      target,
      _scaleYController.velocity,
    );
    unawaited(_scaleXController.animateWith(xSimulation));
    unawaited(_scaleYController.animateWith(ySimulation));
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
    _syncSelectionScaleWithPhase();
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
    // 位置立即用于命中和 Lens 几何；X/Y 的独立 spring 只负责形变，不延迟
    // 业务位置，也不再用逐帧 lerp 制造“表面滞后”。
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
          velocityPixelsPerSecond:
              _phase == LiquidNavPhase.dragging ? _velocityPixelsPerSecond : 0,
          edgeCompression: _phase == LiquidNavPhase.dragging
              ? _controller.edgeCompression
              : 0,
          tuning: widget.tuning,
          springScale: _scaleXController.value,
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
    required double visualIndex,
    required bool showBadge,
    required bool oldV1,
  }) {
    if (oldV1) {
      return _floatingItem(
        icon: icon,
        label: label,
        index: index,
        context: context,
        width: width,
        visualIndex: visualIndex,
        showBadge: showBadge,
      );
    }

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

    if (widget.tuning.isOldV1) {
      final activeT = (1 - (visualIndex - index).abs()).clamp(0.0, 1.0);
      final softenedT = Curves.easeOutCubic.transform(activeT);
      return _NavItemVisualState(
        color: Color.lerp(inactiveColor, AppColors.brandPrimary, softenedT)!,
        fontWeight: FontWeight.w600,
        scale: 1.0,
      );
    }

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
Future<ui.FragmentProgram?>? _liquidGlassV1ProgramFuture;

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

Future<ui.FragmentProgram?> _loadLiquidGlassV1Program() {
  return _liquidGlassV1ProgramFuture ??= () async {
    if (!ui.ImageFilter.isShaderFilterSupported) return null;
    try {
      final program = await ui.FragmentProgram.fromAsset(
        'shaders/liquid_nav_lens_v1.frag',
      );
      updateLiquidGlassRuntimeStatus(
        tier: LiquidGlassTier.a,
        shaderSupported: true,
        detail: '57ca812 old-v1 FragmentShader + ImageFilter.shader',
      );
      return program;
    } catch (error) {
      updateLiquidGlassRuntimeStatus(
        tier: LiquidGlassTier.c,
        shaderSupported: true,
        detail: 'old-v1 shader compile/load failed',
      );
      debugPrint('[LiquidGlass] old-v1 shader load failed: $error');
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

Future<ui.FragmentProgram?>? _liquidGlassHighlightProgramFuture;

Future<ui.FragmentProgram?> _loadLiquidGlassHighlightProgram() {
  return _liquidGlassHighlightProgramFuture ??= () async {
    if (!ui.ImageFilter.isShaderFilterSupported) return null;
    try {
      return await ui.FragmentProgram.fromAsset(
        'shaders/liquid_nav_highlight.frag',
      );
    } catch (error) {
      debugPrint('[LiquidGlass] highlight shader load failed: $error');
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
  ui.FragmentShader? _highlightShader;

  @override
  void initState() {
    super.initState();
    if (widget.useLiquidGlass && widget.useShader && !widget.tuning.isOldV1) {
      _loadShader();
      _loadHighlightShader();
    }
  }

  @override
  void didUpdateWidget(covariant _FloatingDockSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tuning.isOldV1 != widget.tuning.isOldV1) {
      _shader?.dispose();
      _shader = null;
      _highlightShader?.dispose();
      _highlightShader = null;
    }
    if (widget.useLiquidGlass &&
        widget.useShader &&
        !widget.tuning.isOldV1 &&
        (!oldWidget.useLiquidGlass ||
            !oldWidget.useShader ||
            oldWidget.tuning.isOldV1 != widget.tuning.isOldV1) &&
        _shader == null) {
      _loadShader();
      _loadHighlightShader();
    }
  }

  Future<void> _loadShader() async {
    final program = await _loadLiquidGlassDockProgram();
    if (!mounted || program == null || _shader != null) return;
    setState(() => _shader = program.fragmentShader());
  }

  Future<void> _loadHighlightShader() async {
    final program = await _loadLiquidGlassHighlightProgram();
    if (!mounted || program == null || _highlightShader != null) return;
    setState(() => _highlightShader = program.fragmentShader());
  }

  @override
  void dispose() {
    _shader?.dispose();
    _highlightShader?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.useLiquidGlass && widget.tuning.isOldV1) {
      final oldFill = DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: widget.isDark
                ? [
                    const Color(0xFF202526).withValues(
                      alpha: widget.highContrast ? 0.78 : 0.62,
                    ),
                    const Color(0xFF141718).withValues(
                      alpha: widget.highContrast ? 0.74 : 0.48,
                    ),
                  ]
                : [
                    Colors.white.withValues(
                      alpha: widget.highContrast ? 0.86 : 0.62,
                    ),
                    const Color(0xFFEAF6F3).withValues(
                      alpha: widget.highContrast ? 0.78 : 0.42,
                    ),
                  ],
          ),
          border: Border.all(
            color: widget.isDark
                ? Colors.white.withValues(
                    alpha: widget.highContrast ? 0.28 : 0.14,
                  )
                : Colors.white.withValues(
                    alpha: widget.highContrast ? 0.95 : 0.72,
                  ),
            width: widget.highContrast ? 1.25 : 1,
          ),
        ),
      );
      return BackdropFilter(
        filter: ui.ImageFilter.blur(
          sigmaX: widget.isDark ? 17 : 16,
          sigmaY: widget.isDark ? 17 : 16,
        ),
        child: oldFill,
      );
    }

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
            widget.motion.dockOpticalActivation > 0.0001;
        if (canRefract) {
          LiquidGlassDockShaderUniforms(
            logicalSize: constraints.biggest,
            dockSize: constraints.biggest,
            refraction: widget.motion.dockRefraction,
            chromatic: widget.motion.dockChromatic,
            refractionHeight: widget.tuning.dockRefractionHeight,
            activation: widget.motion.dockOpticalActivation,
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
                  painter: LiquidGlassDefaultHighlightPainter(
                    shader: _highlightShader,
                    progress: 1.0,
                    strength: widget.tuning.dockSpecularStrength,
                    highContrast: widget.highContrast,
                    cornerRadius: _dockHeight / 2,
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
    required this.currentIndex,
    required this.screenSize,
    required this.dockGlobalOffset,
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
    required this.springScaleX,
    required this.springScaleY,
    required this.highlightPosition,
    required this.highlightOpacity,
  });

  final _LiquidSelectionLayer layer;
  final Size dockSize;
  final double itemWidth;
  final double visualIndex;
  final int currentIndex;
  final Size screenSize;
  final Offset dockGlobalOffset;
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
  final double springScaleX;
  final double springScaleY;
  final Offset highlightPosition;
  final double highlightOpacity;

  @override
  State<_FloatingLiquidSelection> createState() =>
      _FloatingLiquidSelectionState();
}

class _FloatingLiquidSelectionState extends State<_FloatingLiquidSelection> {
  ui.FragmentShader? _shader;
  ui.FragmentShader? _highlightShader;

  @override
  void initState() {
    super.initState();
    if (widget.useShader) {
      if (widget.tuning.isOldV1 ||
          widget.layer == _LiquidSelectionLayer.backdrop) {
        _loadShader();
      } else {
        _loadHighlightShader();
      }
    }
  }

  Future<void> _loadShader() async {
    final program = widget.tuning.isOldV1
        ? await _loadLiquidGlassV1Program()
        : await _loadLiquidGlassProgram();
    if (!mounted || program == null) return;
    _shader?.dispose();
    setState(() => _shader = program.fragmentShader());
  }

  Future<void> _loadHighlightShader() async {
    final program = await _loadLiquidGlassHighlightProgram();
    if (!mounted || program == null || _highlightShader != null) return;
    setState(() => _highlightShader = program.fragmentShader());
  }

  @override
  void didUpdateWidget(covariant _FloatingLiquidSelection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tuning.isOldV1 != widget.tuning.isOldV1) {
      _shader?.dispose();
      _shader = null;
      _highlightShader?.dispose();
      _highlightShader = null;
    }
    if (widget.useShader && !oldWidget.useShader) {
      if (widget.tuning.isOldV1 ||
          widget.layer == _LiquidSelectionLayer.backdrop) {
        _loadShader();
      } else {
        _loadHighlightShader();
      }
    } else if (widget.useShader &&
        oldWidget.tuning.isOldV1 != widget.tuning.isOldV1) {
      if (widget.tuning.isOldV1 ||
          widget.layer == _LiquidSelectionLayer.backdrop) {
        _loadShader();
      } else {
        _loadHighlightShader();
      }
    }
  }

  @override
  void dispose() {
    _shader?.dispose();
    _highlightShader?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final progress = widget.activation.clamp(0.0, 1.0).toDouble();
    // Dock 自己常驻 Lens；Selection 只在 press/drag/settle 阶段打开。
    final opticalProgress = widget.motion.opticalActivation;
    final hasOpticalMaterial = widget.useLiquidGlass &&
        widget.useShader &&
        opticalProgress > 0.0001 &&
        widget.tuning.effectiveRefractionHeight > 0;
    final speed = widget.motion.speed;
    final direction = widget.motion.direction;
    // 背景光学层、Normal Row 挖空与 Accent 前景必须共享同一几何。
    final selectionRect = _selectionRectFor(
      dockSize: widget.dockSize,
      itemWidth: widget.itemWidth,
      visualIndex: widget.visualIndex,
      currentIndex: widget.currentIndex,
      velocityPixelsPerSecond: widget.velocityPixelsPerSecond,
      edgeCompression: widget.edgeCompression,
      useLiquidGlass: widget.useLiquidGlass,
      tuning: widget.tuning,
      springScaleX: widget.springScaleX,
      springScaleY: widget.springScaleY,
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
      if (widget.tuning.isOldV1) {
        final screenSize = widget.screenSize;
        final globalCenter = Offset(
          widget.dockGlobalOffset.dx + left + lensWidth / 2,
          widget.dockGlobalOffset.dy + top + lensHeight / 2,
        );
        LiquidGlassOldV1ShaderUniforms(
          center: Offset(
            globalCenter.dx / math.max(screenSize.width, 1),
            globalCenter.dy / math.max(screenSize.height, 1),
          ),
          halfSize: Size(
            lensWidth / 2 / math.max(screenSize.width, 1),
            lensHeight / 2 / math.max(screenSize.height, 1),
          ),
          refraction:
              (widget.isDark ? 8.0 : 7.0) / math.max(screenSize.width, 1),
          zoom: widget.tuning.magnification,
          chromatic: widget.tuning.chromatic,
          motion:
              (widget.currentIndex - widget.visualIndex).abs().clamp(0.0, 1.0),
          direction: (widget.currentIndex - widget.visualIndex).sign.toDouble(),
          tint: widget.isDark
              ? AppColors.brandSurfaceDark
              : AppColors.brandSurfaceLight,
        ).apply(shader);
      } else {
        LiquidGlassShaderUniforms(
          captureSize: captureSize,
          lensCenter: captureLensCenter,
          lensSize: visibleSize,
          refractionHeight: widget.tuning.effectiveRefractionHeight,
          refraction: widget.motion.refraction,
          chromatic: widget.motion.chromatic,
          activation: opticalProgress,
        ).apply(shader);
      }
    }

    if (widget.tuning.isOldV1 &&
        widget.layer == _LiquidSelectionLayer.foreground) {
      return _buildOldV1Lens(
        left: left,
        top: top,
        lensWidth: lensWidth,
        lensHeight: lensHeight,
        canRefract: canRefract,
        shader: shader,
      );
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
                  key: const ValueKey(
                    'bottom-nav-selection-default-highlight',
                  ),
                  painter: LiquidGlassDefaultHighlightPainter(
                    shader: _highlightShader,
                    progress: widget.motion.highlightProgress,
                    strength: widget.tuning.highlightStrength,
                    highContrast: widget.highContrast,
                    cornerRadius: lensHeight / 2,
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

  Widget _buildOldV1Lens({
    required double left,
    required double top,
    required double lensWidth,
    required double lensHeight,
    required bool canRefract,
    required ui.FragmentShader? shader,
  }) {
    final lensRadius = BorderRadius.circular(AppRadius.pill);
    final filter = canRefract && shader != null
        ? ui.ImageFilter.shader(shader)
        : ui.ImageFilter.blur(sigmaX: 5, sigmaY: 5);
    final motion =
        (widget.currentIndex - widget.visualIndex).abs().clamp(0.0, 1.0);
    final direction =
        (widget.currentIndex - widget.visualIndex).sign.toDouble();

    return Positioned(
      key: const ValueKey('bottom-nav-selection'),
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
                  alpha: widget.isDark ? 0.28 : 0.12,
                ),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
              BoxShadow(
                color: AppColors.brandPrimary.withValues(
                  alpha: widget.isDark ? 0.18 : 0.10,
                ),
                blurRadius: 16,
                spreadRadius: -4,
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: lensRadius,
            child: Stack(
              fit: StackFit.expand,
              children: [
                BackdropFilter(
                  filter: filter,
                  child: ColoredBox(
                    color: canRefract
                        ? const Color(0x01000000)
                        : (widget.isDark
                            ? Colors.white.withValues(alpha: 0.08)
                            : Colors.white.withValues(alpha: 0.18)),
                  ),
                ),
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Colors.white.withValues(
                          alpha: widget.isDark ? 0.10 : 0.18,
                        ),
                        AppColors.brandPrimary.withValues(
                          alpha: widget.isDark ? 0.08 : 0.04,
                        ),
                        Colors.transparent,
                      ],
                    ),
                  ),
                ),
                CustomPaint(
                  painter: _LiquidLensV1RimPainter(
                    isDark: widget.isDark,
                    highContrast: widget.highContrast,
                    motion: motion,
                    direction: direction,
                    strength: widget.tuning.highlightStrength,
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

class _LiquidLensV1RimPainter extends CustomPainter {
  const _LiquidLensV1RimPainter({
    required this.isDark,
    required this.highContrast,
    required this.motion,
    required this.direction,
    required this.strength,
  });

  final bool isDark;
  final bool highContrast;
  final double motion;
  final double direction;
  final double strength;

  @override
  void paint(Canvas canvas, Size size) {
    final strengthScale = strength.clamp(0.0, 1.5).toDouble();
    final rect = (Offset.zero & size).deflate(highContrast ? 0.8 : 0.6);
    final radius = Radius.circular(size.height / 2);
    final rim = RRect.fromRectAndRadius(rect, radius);
    final begin = direction < 0 ? Alignment.topRight : Alignment.topLeft;
    final end = direction < 0 ? Alignment.bottomLeft : Alignment.bottomRight;
    final rimPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = highContrast ? 1.6 : 1.15
      ..shader = LinearGradient(
        begin: begin,
        end: end,
        colors: [
          Colors.white.withValues(
            alpha: (highContrast ? 0.96 : 0.82) * strengthScale,
          ),
          const Color(0xFF8FE9DF).withValues(
            alpha: (isDark ? 0.62 : 0.48) * strengthScale,
          ),
          Colors.white.withValues(alpha: 0.18 * strengthScale),
          const Color(0xFF9C8CFF).withValues(
            alpha: (0.28 + motion * 0.14) * strengthScale,
          ),
          Colors.white.withValues(
            alpha: (highContrast ? 0.78 : 0.52) * strengthScale,
          ),
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
      ..strokeWidth = highContrast ? 1.2 : 0.8
      ..shader = LinearGradient(
        colors: [
          Colors.white.withValues(alpha: 0),
          Colors.white.withValues(
            alpha: (highContrast ? 0.88 : 0.62) * strengthScale,
          ),
          Colors.white.withValues(alpha: 0),
        ],
      ).createShader(highlightRect);
    canvas.drawArc(highlightRect, math.pi, math.pi, false, highlightPaint);
  }

  @override
  bool shouldRepaint(covariant _LiquidLensV1RimPainter oldDelegate) {
    return oldDelegate.isDark != isDark ||
        oldDelegate.highContrast != highContrast ||
        oldDelegate.motion != motion ||
        oldDelegate.direction != direction ||
        oldDelegate.strength != strength;
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
                velocityPixelsPerSecond: phase == LiquidNavPhase.dragging
                    ? velocityPixelsPerSecond
                    : 0,
                edgeCompression:
                    phase == LiquidNavPhase.dragging ? edgeCompression : 0,
                tuning: tuning,
                springScale: ui.lerpDouble(
                  1.0,
                  tuning.pressedScale,
                  activation,
                )!,
              );
          final lensHeight = _selectionHeight *
              _selectionScaleY(
                velocityPixelsPerSecond: phase == LiquidNavPhase.dragging
                    ? velocityPixelsPerSecond
                    : 0,
                edgeCompression:
                    phase == LiquidNavPhase.dragging ? edgeCompression : 0,
                tuning: tuning,
                springScale: ui.lerpDouble(
                  1.0,
                  tuning.pressedScale,
                  activation,
                )!,
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
