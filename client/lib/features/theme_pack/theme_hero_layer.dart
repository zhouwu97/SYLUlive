import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../theme/app_theme_tokens.dart';
import '../../utils/app_navigator.dart';
import 'theme_presentation.dart';
import 'themed_wallpaper_layer.dart';

/// 沉浸页头的 hero 位置登记。
///
/// hero 图画在页面背景层里（顶栏、搜索框、内容都叠在它上面），内容区只放一个锚点。
/// 锚点在每次滚动后的下一帧报告自己在屏幕上的底边位置，背景层据此让 hero 跟随内容
/// 视差上移并淡出。背景层不是内容的父级，所以用这个单例在两者之间传递位置。
class ThemeHeroController extends ChangeNotifier {
  ThemeHeroController._();

  static final ThemeHeroController instance = ThemeHeroController._();

  final Map<String, _ThemeHeroAnchorState> _anchors = {};
  final Map<String, double> _bottom = {};
  final Map<String, double> _restBottom = {};
  final Map<String, double> _extend = {};
  bool _measureScheduled = false;

  /// 锚点底边当前的全局纵坐标；槽位没有锚点时为 null。
  double? bottomOf(String slot) => _bottom[slot];

  /// 锚点静止（未滚动）时的底边位置，作为 hero 的完整高度。
  double? restBottomOf(String slot) => _restBottom[slot];

  /// hero 铺到锚点下方吸顶控件背后的高度；这段需要更重的底色遮罩保证控件可读。
  double extendOf(String slot) => _extend[slot] ?? 0;

  void _register(String slot, _ThemeHeroAnchorState anchor) {
    _anchors[slot] = anchor;
    scheduleMeasure();
  }

  void _unregister(String slot, _ThemeHeroAnchorState anchor) {
    if (_anchors[slot] != anchor) return;
    _anchors.remove(slot);
    _bottom.remove(slot);
    _restBottom.remove(slot);
    _extend.remove(slot);
    notifyListeners();
  }

  /// 滚动或布局变化后调用；同一帧内多次调用只测量一次。
  void scheduleMeasure() {
    if (_measureScheduled) return;
    _measureScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _measureScheduled = false;
      var changed = false;
      for (final entry in _anchors.entries) {
        final measured = entry.value._measure();
        if (measured == null) continue;
        final (bottom, scrolled) = measured;
        // 静止位置 = 当前位置 + 已滚动距离；直接由滚动偏移推出，不受切页动画的瞬时位移影响。
        final rest = bottom + scrolled;
        final extend = entry.value.widget.extend;
        if ((_extend[entry.key] ?? 0) != extend) {
          _extend[entry.key] = extend;
          changed = true;
        }
        if ((_bottom[entry.key] ?? double.nan) != bottom ||
            (_restBottom[entry.key] ?? double.nan) != rest) {
          _bottom[entry.key] = bottom;
          _restBottom[entry.key] = rest;
          changed = true;
        }
      }
      if (changed) notifyListeners();
    });
  }
}

/// 内容区里的锚点：本身只占 [height] 的透明空间，hero 图在背景层里绘制到它的底边下方 [ThemeHeroLayer.overlap] 处。
class ThemeHeroAnchor extends StatefulWidget {
  const ThemeHeroAnchor({
    super.key,
    required this.slot,
    this.height = 0,
    this.extend = 0,
  });

  final String slot;
  final double height;

  /// hero 继续向锚点下方延伸的距离，用于让图铺到紧随其后的吸顶控件背后。
  final double extend;

  @override
  State<ThemeHeroAnchor> createState() => _ThemeHeroAnchorState();
}

class _ThemeHeroAnchorState extends State<ThemeHeroAnchor> {
  @override
  void initState() {
    super.initState();
    ThemeHeroController.instance._register(widget.slot, this);
  }

  @override
  void didUpdateWidget(ThemeHeroAnchor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.slot != widget.slot) {
      ThemeHeroController.instance._unregister(oldWidget.slot, this);
      ThemeHeroController.instance._register(widget.slot, this);
    } else if (oldWidget.height != widget.height ||
        oldWidget.extend != widget.extend) {
      ThemeHeroController.instance.scheduleMeasure();
    }
  }

  @override
  void dispose() {
    ThemeHeroController.instance._unregister(widget.slot, this);
    super.dispose();
  }

  /// 返回（底边全局纵坐标，所在滚动视图已滚动的距离）。
  (double, double)? _measure() {
    if (!mounted) return null;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize || !box.attached) return null;
    final position = Scrollable.maybeOf(context)?.position;
    final scrolled = position != null && position.hasPixels
        ? math.max(0.0, position.pixels)
        : 0.0;
    final bottom = box.localToGlobal(Offset(0, box.size.height)).dy;
    return (bottom + widget.extend, scrolled);
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: ValueKey('theme-hero-anchor-${widget.slot}'),
      height: widget.height,
    );
  }
}

/// 把垂直滚动转成锚点重新测量。挂在主壳上，覆盖首页、校园、我三个页签的全部滚动视图。
class ThemeHeroScrollListener extends StatelessWidget {
  const ThemeHeroScrollListener({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification.metrics.axis == Axis.vertical) {
          ThemeHeroController.instance.scheduleMeasure();
        }
        return false;
      },
      child: NotificationListener<SizeChangedLayoutNotification>(
        onNotification: (_) {
          ThemeHeroController.instance.scheduleMeasure();
          return false;
        },
        child: child,
      ),
    );
  }
}

/// 背景层中的沉浸 hero。只在主壳当前页签对应的槽位为 immersive 且有页头背景或贴纸时绘制。
class ThemeHeroLayer extends StatelessWidget {
  const ThemeHeroLayer({super.key});

  /// hero 底边超出锚点的距离，即第一张内容卡压住 hero 的高度。
  static const double overlap = 28;

  static String? slotForTab(int tab) => switch (tab) {
        0 => 'home',
        3 => 'campus',
        4 => 'me',
        _ => null,
      };

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: currentHomeTabIndex,
      builder: (context, tab, _) {
        final slot = slotForTab(tab);
        if (slot == null) return const SizedBox.shrink();
        // 切换页签后重新测量一次，保活页签的锚点位置可能在后台变化过。
        ThemeHeroController.instance.scheduleMeasure();
        final resolved = ThemeHeaderResolved.of(context, slot);
        if (resolved.layout.preset != 'immersive' || !resolved.hasDecoration) {
          return const SizedBox.shrink();
        }
        return ListenableBuilder(
          listenable: ThemeHeroController.instance,
          builder: (context, _) {
            final controller = ThemeHeroController.instance;
            final bottom = controller.bottomOf(slot);
            final rest = controller.restBottomOf(slot);
            if (bottom == null || rest == null || rest <= 0) {
              return const SizedBox.shrink();
            }
            final heroHeight = rest + overlap;
            final scrolled = (rest - bottom).clamp(0.0, heroHeight);
            final extend = controller.extendOf(slot);
            final art = _ThemeHeroArt(
              slot: slot,
              resolved: resolved,
              height: heroHeight,
              controlsHeight: extend + overlap,
            );
            if (extend > 0) {
              // 图铺到吸顶控件背后时不淡出：控件吸顶那一刻视差定格，
              // hero 被裁成状态栏 + 控件高度的横幅，继续留在顶栏背后。
              final pinnedBottom =
                  MediaQuery.paddingOf(context).top + extend - 4;
              final pinScroll = math.max(0.0, rest - pinnedBottom);
              final shift = math.min(scrolled, pinScroll) * 0.5;
              return Positioned(
                left: 0,
                right: 0,
                top: 0,
                height: math.max(heroHeight - scrolled, pinnedBottom),
                child: Stack(
                  clipBehavior: Clip.hardEdge,
                  children: [
                    Positioned(
                      left: 0,
                      right: 0,
                      top: -shift,
                      height: heroHeight,
                      child: art,
                    ),
                  ],
                ),
              );
            }
            // 视差：hero 以内容一半的速度上移；滚过 hero 高度的 70% 时完全淡出。
            final progress = (scrolled / (heroHeight * 0.7)).clamp(0.0, 1.0);
            final opacity = 1.0 - Curves.easeIn.transform(progress);
            if (opacity <= 0.01) return const SizedBox.shrink();
            return Positioned(
              left: 0,
              right: 0,
              top: -scrolled * 0.5,
              height: heroHeight,
              child: Opacity(opacity: opacity, child: art),
            );
          },
        );
      },
    );
  }
}

/// 校园、我两页没有吸顶顶栏：内容滚过 hero 后在状态栏后面补一条页面底色，
/// 卡片不会直接压在状态栏图标下面。首页自带吸顶状态栏条，不用这里。
class ThemeStatusBarScrim extends StatelessWidget {
  const ThemeStatusBarScrim({super.key});

  @override
  Widget build(BuildContext context) {
    final inset = MediaQuery.paddingOf(context).top;
    if (inset <= 0) return const SizedBox.shrink();
    return ValueListenableBuilder<int>(
      valueListenable: currentHomeTabIndex,
      builder: (context, tab, _) {
        final slot = switch (tab) {
          3 => 'campus',
          4 => 'me',
          _ => null,
        };
        if (slot == null) return const SizedBox.shrink();
        return ListenableBuilder(
          listenable: ThemeHeroController.instance,
          builder: (context, _) {
            final controller = ThemeHeroController.instance;
            final bottom = controller.bottomOf(slot);
            final rest = controller.restBottomOf(slot);
            if (bottom == null || rest == null || rest <= inset) {
              return const SizedBox.shrink();
            }
            // 锚点底边（信息卡上沿）离状态栏还剩 48 像素时开始补底色。
            final t = ((inset + 48 - bottom) / 48).clamp(0.0, 1.0);
            if (t <= 0) return const SizedBox.shrink();
            final background = AppThemeTokens.of(context).background;
            return IgnorePointer(
              child: SizedBox(
                height: inset,
                width: double.infinity,
                child: ColoredBox(
                  color: background.withValues(alpha: 0.94 * t),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// 吸顶控件里的 hero 切片：按控件在屏幕上的位置 [top] 画出与背景层同一处的 hero 画面，
/// 自身不透明，滚到控件下面的内容不会透出来。控件吸顶时视差定格，切片成为顶栏横幅。
class ThemeHeroSlice extends StatelessWidget {
  const ThemeHeroSlice({
    super.key,
    required this.slot,
    required this.top,
    required this.scrollOffset,
  });

  final String slot;
  final double top;
  final double scrollOffset;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ThemeHeroController.instance,
      builder: (context, _) => _build(context),
    );
  }

  Widget _build(BuildContext context) {
    final controller = ThemeHeroController.instance;
    final rest = controller.restBottomOf(slot);
    final extend = controller.extendOf(slot);
    final background = AppThemeTokens.of(context).background;
    if (rest == null || rest <= 0) return ColoredBox(color: background);
    final heroHeight = rest + ThemeHeroLayer.overlap;
    final pinnedBottom = MediaQuery.paddingOf(context).top + extend - 4;
    final pinScroll = math.max(0.0, rest - pinnedBottom);
    final shift = math.min(math.max(0.0, scrollOffset), pinScroll) * 0.5;
    return ColoredBox(
      color: background,
      child: Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          Positioned(
            left: 0,
            right: 0,
            top: -top - shift,
            height: heroHeight,
            child: _ThemeHeroArt(
              slot: slot,
              resolved: ThemeHeaderResolved.of(context, slot),
              height: heroHeight,
              controlsHeight: extend + ThemeHeroLayer.overlap,
            ),
          ),
        ],
      ),
    );
  }
}

class _ThemeHeroArt extends StatelessWidget {
  /// 顶部压一层页面底色保证状态栏可读；底部渐隐进页面。图铺到控件背后时，
  /// 从控件上沿开始加重遮罩，标签和搜索框落在半透明底色上。
  LinearGradient _scrim(Color background) {
    final controls = (controlsHeight / height).clamp(0.0, 0.6);
    if (controls <= ThemeHeroLayer.overlap / height + 0.001) {
      return LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        stops: const [0.0, 0.32, 0.55, 0.82, 1.0],
        colors: [
          background.withValues(alpha: 0.62),
          background.withValues(alpha: 0.0),
          background.withValues(alpha: 0.0),
          background.withValues(alpha: 0.72),
          background,
        ],
      );
    }
    final top = 1.0 - controls;
    return LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      stops: [0.0, top * 0.3, top - 0.12, top, top + controls * 0.45, 1.0],
      colors: [
        background.withValues(alpha: 0.6),
        background.withValues(alpha: 0.0),
        background.withValues(alpha: 0.0),
        background.withValues(alpha: 0.42),
        background.withValues(alpha: 0.82),
        background,
      ],
    );
  }


  const _ThemeHeroArt({
    required this.slot,
    required this.resolved,
    required this.height,
    this.controlsHeight = 0,
  });

  final String slot;
  final ThemeHeaderResolved resolved;
  final double height;

  /// hero 底部压在吸顶控件后面的高度；为 [ThemeHeroLayer.overlap] 时说明没有控件。
  final double controlsHeight;

  @override
  Widget build(BuildContext context) {
    final background = AppThemeTokens.of(context).background;
    final rawBackground = resolved.background;
    final imagePath = rawBackground?['image'] as String?;
    final width = MediaQuery.sizeOf(context).width;
    final layout = resolved.layout;
    return ExcludeSemantics(
      child: IgnorePointer(
        child: SizedBox(
          key: ValueKey('theme-hero-$slot'),
          width: width,
          height: height,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (rawBackground != null && imagePath != null)
                ThemedWallpaperLayer(
                  settings: <String, dynamic>{
                    ...rawBackground,
                    'portrait': imagePath,
                    // hero 自身用渐隐处理边缘，不叠加整体遮罩。
                    'scrim': 0.0,
                  },
                  imageProvider: resolved.assetResolver(imagePath),
                ),
              // 顶部用页面底色压一层，保证状态栏、顶栏文字和搜索框在任何图上都清楚。
              DecoratedBox(
                decoration: BoxDecoration(gradient: _scrim(background)),
              ),
              // 贴纸坐标按 hero 区域（整宽、整高）换算，画在渐隐层之上。
              if (resolved.stickers.isNotEmpty)
                Positioned.fill(
                  child: ThemeHeaderDecorationArea(
                    slot: '$slot-hero',
                    layout: ThemeHeaderLayoutSpec(
                      preset: layout.preset,
                      alignment: layout.alignment,
                      imageHeight: layout.imageHeight,
                      imageWidth: 1.0,
                    ),
                    background: null,
                    stickers: resolved.stickers,
                    assetResolver: resolved.assetResolver,
                    transparent: true,
                    boxHeight: height,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
