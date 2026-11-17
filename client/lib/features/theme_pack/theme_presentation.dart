import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/theme_provider.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_theme_tokens.dart';
import 'theme_appearance.dart';
import 'theme_manifest.dart';
import 'themed_wallpaper_layer.dart';

typedef ThemeAssetProviderResolver = ImageProvider? Function(String path);

/// 为主题导入预览、设置编辑与主题工坊提供候选外观覆盖，正式页面不挂载时直接读取 ThemeProvider。
class ThemePresentationOverride extends InheritedWidget {
  const ThemePresentationOverride({
    super.key,
    required this.appearance,
    this.brightnessOverride,
    this.assetResolver,
    required super.child,
  });

  final ThemeAppearance appearance;
  final Brightness? brightnessOverride;
  final ThemeAssetProviderResolver? assetResolver;

  static ThemePresentationOverride? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ThemePresentationOverride>();

  @override
  bool updateShouldNotify(ThemePresentationOverride oldWidget) =>
      oldWidget.appearance.data != appearance.data ||
      oldWidget.brightnessOverride != brightnessOverride ||
      oldWidget.assetResolver != assetResolver;
}

class ThemeHeaderLayoutSpec {
  const ThemeHeaderLayoutSpec({
    this.preset = 'standard',
    this.alignment = 'start',
    this.imageHeight = 160.0,
    this.imageWidth = 1.0,
  });

  final String preset;
  final String alignment;
  final double imageHeight;
  final double imageWidth;

  factory ThemeHeaderLayoutSpec.fromMap(Map<String, dynamic>? raw) {
    if (raw == null) return const ThemeHeaderLayoutSpec();
    final preset = raw['preset'] as String?;
    final alignment = raw['alignment'] as String?;
    final height = (raw['imageHeight'] as num?)?.toDouble() ?? 160.0;
    final width = (raw['imageWidth'] as num?)?.toDouble() ?? 1.0;
    return ThemeHeaderLayoutSpec(
      preset: const {'standard', 'compact', 'immersive'}.contains(preset)
          ? preset!
          : 'standard',
      alignment: const {'start', 'center', 'end'}.contains(alignment)
          ? alignment!
          : 'start',
      imageHeight: height.isFinite ? height.clamp(96.0, 280.0) : 160.0,
      imageWidth: width.isFinite ? width.clamp(0.45, 1.0) : 1.0,
    );
  }

  CrossAxisAlignment get crossAxisAlignment => switch (alignment) {
        'center' => CrossAxisAlignment.center,
        'end' => CrossAxisAlignment.end,
        _ => CrossAxisAlignment.start,
      };

  MainAxisAlignment get mainAxisAlignment => switch (alignment) {
        'center' => MainAxisAlignment.center,
        'end' => MainAxisAlignment.end,
        _ => MainAxisAlignment.start,
      };

  Alignment get boxAlignment => switch (alignment) {
        'center' => Alignment.center,
        'end' => Alignment.centerRight,
        _ => Alignment.centerLeft,
      };

  TextAlign get textAlign => switch (alignment) {
        'center' => TextAlign.center,
        'end' => TextAlign.right,
        _ => TextAlign.left,
      };

  Map<String, dynamic> toJson() => {
        'preset': preset,
        'alignment': alignment,
        'imageHeight': imageHeight,
        'imageWidth': imageWidth,
      };
}

class ThemeCardStyleSpec {
  const ThemeCardStyleSpec({
    this.borderWidth,
    this.shadow,
  });

  final double? borderWidth;
  final String? shadow;

  bool get hasOverrides => borderWidth != null || shadow != null;

  static ThemeCardStyleSpec? resolve(BuildContext context) {
    final override = ThemePresentationOverride.maybeOf(context);
    final brightness = override?.brightnessOverride ?? Theme.of(context).brightness;
    final mode = brightness == Brightness.dark ? 'dark' : 'light';
    final appearance = override?.appearance ??
        context.watch<ThemeProvider?>()?.appearance;
    final materialGroup = appearance?.group(ThemeGroup.material);
    if (materialGroup == null || materialGroup['legacy'] == true) return null;
    final modeMat = materialGroup[mode] as Map?;
    final raw = modeMat?['cardStyle'] as Map?;
    if (raw == null || raw.isEmpty) return null;
    final bw = (raw['borderWidth'] as num?)?.toDouble();
    final sh = raw['shadow'] as String?;
    final spec = ThemeCardStyleSpec(
      borderWidth:
          (bw != null && bw.isFinite) ? bw.clamp(0.0, 2.0) : null,
      shadow: const {'none', 'soft', 'medium'}.contains(sh) ? sh : null,
    );
    return spec.hasOverrides ? spec : null;
  }

  BoxBorder? resolveBoxBorder(BuildContext context) {
    final bw = borderWidth;
    if (bw == null) return null;
    if (bw <= 0) return const Border();
    return Border.all(
      color: AppThemeTokens.of(context).cardBorder,
      width: bw,
    );
  }

  BorderSide? resolveBorderSide(BuildContext context) {
    final bw = borderWidth;
    if (bw == null) return null;
    if (bw <= 0) return BorderSide.none;
    return BorderSide(
      color: AppThemeTokens.of(context).cardBorder,
      width: bw,
    );
  }

  List<BoxShadow>? resolveBoxShadows(bool isDark) {
    final sh = shadow;
    if (sh == null) return null;
    return switch (sh) {
      'none' => const <BoxShadow>[],
      'soft' => [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.12 : 0.08),
            offset: const Offset(0, 2),
            blurRadius: 8,
            spreadRadius: 0,
          ),
        ],
      'medium' => [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.18 : 0.12),
            offset: const Offset(0, 4),
            blurRadius: 16,
            spreadRadius: 0,
          ),
        ],
      _ => null,
    };
  }
}

/// 解析当前上下文在指定页头槽位（home / campus / me）的布局与装饰配置。
class ThemeHeaderResolved {
  const ThemeHeaderResolved({
    required this.hasCustomLayout,
    required this.layout,
    required this.background,
    required this.stickers,
    required this.assetResolver,
  });

  final bool hasCustomLayout;
  final ThemeHeaderLayoutSpec layout;
  final Map<String, dynamic>? background;
  final List<Map<String, dynamic>> stickers;
  final ThemeAssetProviderResolver assetResolver;

  bool get hasDecoration => background != null || stickers.isNotEmpty;
  bool get isCustomized => hasCustomLayout || hasDecoration;

  static ThemeHeaderResolved of(BuildContext context, String slot) {
    final override = ThemePresentationOverride.maybeOf(context);
    final brightness =
        override?.brightnessOverride ?? Theme.of(context).brightness;
    final mode = brightness == Brightness.dark ? 'dark' : 'light';
    final appearance = override?.appearance ??
        context.watch<ThemeProvider?>()?.appearance ??
        const ThemeAppearance.empty();

    final layoutMap = appearance.group(ThemeGroup.layout)?['value'] as Map?;
    final rawHeader = layoutMap?[slot] as Map<String, dynamic>?;

    final decoGroup = appearance.group(ThemeGroup.decoration);
    final modeDeco = decoGroup?[mode] as Map?;
    final rawDeco = modeDeco?[slot] as Map?;
    final rawBg = rawDeco?['background'] as Map?;
    final rawStickers = (rawDeco?['stickers'] as List?) ?? const [];
    final stickers = <Map<String, dynamic>>[
      for (final item in rawStickers.take(5))
        if (item is Map) Map<String, dynamic>.from(item),
    ];

    ImageProvider? defaultResolver(String rawPath) {
      if (rawPath.isEmpty) return null;
      return FileImage(File(rawPath));
    }

    return ThemeHeaderResolved(
      hasCustomLayout: rawHeader != null,
      layout: ThemeHeaderLayoutSpec.fromMap(rawHeader),
      background: rawBg == null ? null : Map<String, dynamic>.from(rawBg),
      stickers: stickers,
      assetResolver: override?.assetResolver ?? defaultResolver,
    );
  }
}

/// 页头独立装饰区：无背景且无贴纸时不占位；正式页面严格包裹 IgnorePointer + ExcludeSemantics。
class ThemeHeaderDecorationArea extends StatelessWidget {
  const ThemeHeaderDecorationArea({
    super.key,
    required this.slot,
    required this.layout,
    required this.background,
    required this.stickers,
    required this.assetResolver,
    this.interactive = false,
    this.selectedStickerIndex,
    this.onStickerSelected,
    this.onStickerDragChanged,
  });

  final String slot;
  final ThemeHeaderLayoutSpec layout;
  final Map<String, dynamic>? background;
  final List<Map<String, dynamic>> stickers;
  final ThemeAssetProviderResolver assetResolver;
  final bool interactive;
  final int? selectedStickerIndex;
  final ValueChanged<int>? onStickerSelected;
  final void Function(int index, double x, double y)? onStickerDragChanged;

  @override
  Widget build(BuildContext context) {
    if (background == null && stickers.isEmpty) {
      return const SizedBox.shrink();
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        final boxWidth =
            (availableWidth * layout.imageWidth).clamp(1.0, availableWidth);
        final boxHeight = layout.imageHeight.clamp(96.0, 280.0);
        final dpr = MediaQuery.devicePixelRatioOf(context);
        final radius = BorderRadius.circular(AppShape.of(context).lg);

        final bgImagePath = background?['image'] as String?;
        final bgSettings = background == null
            ? null
            : <String, dynamic>{
                ...background!,
                'portrait': bgImagePath ?? '',
              };

        Widget box = SizedBox(
          key: ValueKey('theme-header-decoration-$slot'),
          width: boxWidth,
          height: boxHeight,
          child: ClipRRect(
            borderRadius: radius,
            child: Stack(
              clipBehavior: Clip.hardEdge,
              children: [
                Positioned.fill(
                  child: ColoredBox(
                    color: AppThemeTokens.of(context).surfaceMuted,
                  ),
                ),
                if (bgSettings != null && bgImagePath != null)
                  Positioned.fill(
                    child: ThemedWallpaperLayer(
                      settings: bgSettings,
                      imageProvider: assetResolver(bgImagePath),
                    ),
                  ),
                for (var i = 0; i < math.min(5, stickers.length); i++)
                  _buildSticker(
                    context: context,
                    index: i,
                    sticker: stickers[i],
                    boxWidth: boxWidth,
                    boxHeight: boxHeight,
                    dpr: dpr,
                  ),
              ],
            ),
          ),
        );

        if (!interactive) {
          box = ExcludeSemantics(
            child: IgnorePointer(
              child: box,
            ),
          );
        }

        return Align(
          alignment: layout.boxAlignment,
          child: box,
        );
      },
    );
  }

  Widget _buildSticker({
    required BuildContext context,
    required int index,
    required Map<String, dynamic> sticker,
    required double boxWidth,
    required double boxHeight,
    required double dpr,
  }) {
    final imagePath = sticker['image'] as String? ?? '';
    final rawProvider = assetResolver(imagePath);
    if (rawProvider == null) return const SizedBox.shrink();

    final x = ((sticker['x'] as num?)?.toDouble() ?? 0.5).clamp(0.0, 1.0);
    final y = ((sticker['y'] as num?)?.toDouble() ?? 0.5).clamp(0.0, 1.0);
    final widthRatio =
        ((sticker['width'] as num?)?.toDouble() ?? 0.2).clamp(0.08, 0.40);
    final rotationDeg =
        ((sticker['rotation'] as num?)?.toDouble() ?? 0.0).clamp(-180.0, 180.0);

    final stickerWidth = (boxWidth * widthRatio).clamp(12.0, boxWidth);
    final decodeWidth = (stickerWidth * dpr).round().clamp(32, 1024);
    final provider = ResizeImage(
      rawProvider,
      width: decodeWidth,
      policy: ResizeImagePolicy.fit,
    );

    Widget visual = Transform.rotate(
      angle: rotationDeg * math.pi / 180.0,
      alignment: Alignment.center,
      child: Image(
        image: provider,
        width: stickerWidth,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.medium,
        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
      ),
    );

    if (interactive) {
      final isSelected = selectedStickerIndex == index;
      visual = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onStickerSelected?.call(index),
        onPanUpdate: (details) {
          if (onStickerDragChanged == null) return;
          final nextX = (x + details.delta.dx / boxWidth).clamp(0.0, 1.0);
          final nextY = (y + details.delta.dy / boxHeight).clamp(0.0, 1.0);
          onStickerDragChanged!(index, nextX, nextY);
        },
        child: DecoratedBox(
          decoration: isSelected
              ? BoxDecoration(
                  border: Border.all(
                    color: AppThemeTokens.of(context).primary,
                    width: 1.5,
                  ),
                  borderRadius: BorderRadius.circular(6),
                )
              : const BoxDecoration(),
          child: visual,
        ),
      );
    }

    return Positioned(
      key: ValueKey('theme-sticker-$slot-$index'),
      left: x * boxWidth,
      top: y * boxHeight,
      width: stickerWidth,
      child: FractionalTranslation(
        translation: const Offset(-0.5, -0.5),
        child: visual,
      ),
    );
  }
}

/// 统一组装页头三大预设（standard / compact / immersive）与独立装饰区。
/// 未配置任何本槽位布局或装饰时走 [defaultBuilder]，确保 P0 默认路径零视觉变化。
class ThemeHeaderFrame extends StatelessWidget {
  const ThemeHeaderFrame({
    super.key,
    required this.slot,
    required this.defaultBuilder,
    required this.standardInfoBuilder,
    required this.compactInfoBuilder,
    this.spacing = 8.0,
  });

  final String slot;
  final WidgetBuilder defaultBuilder;
  final Widget Function(BuildContext context, ThemeHeaderLayoutSpec layout)
      standardInfoBuilder;
  final Widget Function(BuildContext context, ThemeHeaderLayoutSpec layout)
      compactInfoBuilder;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    final resolved = ThemeHeaderResolved.of(context, slot);
    if (!resolved.isCustomized) {
      return defaultBuilder(context);
    }

    final layout = resolved.layout;
    final infoWidget = layout.preset == 'compact'
        ? compactInfoBuilder(context, layout)
        : standardInfoBuilder(context, layout);

    if (!resolved.hasDecoration) {
      return infoWidget;
    }

    final decorationWidget = ThemeHeaderDecorationArea(
      slot: slot,
      layout: layout,
      background: resolved.background,
      stickers: resolved.stickers,
      assetResolver: resolved.assetResolver,
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: layout.preset == 'immersive'
          ? [
              decorationWidget,
              SizedBox(height: spacing),
              infoWidget,
            ]
          : [
              infoWidget,
              SizedBox(height: spacing),
              decorationWidget,
            ],
    );
  }
}

/// 首页（home）信息流顶部主题页头：仅在配置了 home 布局或装饰时渲染，默认路径高度为 0。
class HomeThemedHeaderBanner extends StatelessWidget {
  const HomeThemedHeaderBanner({
    super.key,
    required this.feedModeLabel,
  });

  final String feedModeLabel;

  @override
  Widget build(BuildContext context) {
    final resolved = ThemeHeaderResolved.of(context, 'home');
    if (!resolved.isCustomized) {
      return const SizedBox.shrink();
    }

    final tokens = AppThemeTokens.of(context);
    final shape = AppShape.of(context);

    Widget buildInfoCard(ThemeHeaderLayoutSpec layout, {required bool compact}) {
      return Container(
        key: const ValueKey('home-themed-header-info'),
        padding: EdgeInsets.symmetric(
          horizontal: 14,
          vertical: compact ? 8 : 12,
        ),
        decoration: BoxDecoration(
          // 页头信息区使用不透明 card 底面，保证文字可读性不受装饰图片影响。
          color: tokens.card,
          borderRadius: BorderRadius.circular(shape.lg),
          border: Border.all(color: tokens.cardBorder),
        ),
        child: compact
            ? Align(
                alignment: layout.boxAlignment,
                child: Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  alignment: switch (layout.alignment) {
                    'center' => WrapAlignment.center,
                    'end' => WrapAlignment.end,
                    _ => WrapAlignment.start,
                  },
                  children: [
                    Text(
                      '沈理社区',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: tokens.textPrimary,
                      ),
                    ),
                    Text(
                      '当前浏览 · $feedModeLabel',
                      style: TextStyle(
                        fontSize: 12,
                        color: tokens.textSecondary,
                      ),
                    ),
                  ],
                ),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: layout.crossAxisAlignment,
                children: [
                  Text(
                    '沈理社区',
                    textAlign: layout.textAlign,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: tokens.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '校园动态 · $feedModeLabel',
                    textAlign: layout.textAlign,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: tokens.textSecondary,
                    ),
                  ),
                ],
              ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
      child: ThemeHeaderFrame(
        slot: 'home',
        defaultBuilder: (_) => const SizedBox.shrink(),
        standardInfoBuilder: (_, layout) => buildInfoCard(layout, compact: false),
        compactInfoBuilder: (_, layout) => buildInfoCard(layout, compact: true),
      ),
    );
  }
}
