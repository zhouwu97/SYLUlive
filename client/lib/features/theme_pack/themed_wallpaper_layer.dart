import 'dart:async';
import 'dart:math' as math;
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../theme/app_theme_tokens.dart';

class ThemedWallpaperLayer extends StatelessWidget {
  const ThemedWallpaperLayer(
      {super.key, required this.settings, this.imageProvider, this.backdrop});
  final Map<String, dynamic>? settings;
  final ImageProvider? imageProvider;

  /// 没有壁纸图片的页面使用的氛围背景；有壁纸图片时被图片完整覆盖，不绘制。
  final Map<String, dynamic>? backdrop;

  /// 按契约 2.9 顺序（亮度 → 对比度 → 饱和度）生成 4×5 颜色矩阵；中性参数返回单位矩阵。
  static List<double> buildColorMatrix({
    double brightness = 0,
    double contrast = 100,
    double saturation = 100,
  }) {
    final c = contrast / 100.0;
    final s = saturation / 100.0;
    final offset = brightness * 2.55 * c + 127.5 * (1.0 - c);
    final inverse = 1.0 - s;
    final r = 0.2126 * inverse * c;
    final g = 0.7152 * inverse * c;
    final b = 0.0722 * inverse * c;
    final diag = s * c;
    return <double>[
      r + diag, g, b, 0, offset,
      r, g + diag, b, 0, offset,
      r, g, b + diag, 0, offset,
      0, 0, 0, 1, 0,
    ];
  }

  static bool isNeutralAdjustments(Map? adjustment) {
    if (adjustment == null) return true;
    final brightness = (adjustment['brightness'] as num? ?? 0).toDouble();
    final contrast = (adjustment['contrast'] as num? ?? 100).toDouble();
    final saturation = (adjustment['saturation'] as num? ?? 100).toDouble();
    return brightness == 0 && contrast == 100 && saturation == 100;
  }

  /// 壁纸图片的解码尺寸按显示物理宽度缩放；预解码与正式绘制必须用同一个 provider 才能命中缓存。
  static ImageProvider providerFor(
      BuildContext context, Map<String, dynamic> config) {
    final landscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final file = (landscape ? config['landscape'] : null) ?? config['portrait'];
    final physicalWidth = (MediaQuery.sizeOf(context).width *
            MediaQuery.devicePixelRatioOf(context))
        .round()
        .clamp(100, 4096);
    return ResizeImage(
      FileImage(File(file as String)),
      width: physicalWidth,
      policy: ResizeImagePolicy.fit,
      allowUpscaling: false,
    );
  }

  /// 预先解码各页签与二级页面的壁纸。切页时图片已在缓存里，新页面首帧就能画出壁纸，
  /// 不会先露出底色再出现图片。
  static void precache(
      BuildContext context, Iterable<Map<String, dynamic>> configs) {
    for (final config in configs) {
      unawaited(precacheImage(
        providerFor(context, config),
        context,
        onError: (_, __) {},
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final config = settings;
    final background = AppThemeTokens.of(context).background;
    if (config == null) {
      return SizedBox.expand(
        child: backdrop == null
            ? ColoredBox(color: background)
            : ThemeBackdropLayer(backdrop: backdrop!, background: background),
      );
    }
    final adjustment = config['adjustments'] as Map?;
    final brightness = (adjustment?['brightness'] as num? ?? 0).toDouble();
    final contrast = (adjustment?['contrast'] as num? ?? 100).toDouble();
    final saturation = (adjustment?['saturation'] as num? ?? 100).toDouble();
    final fit = config['fit'] == 'contain' ? BoxFit.contain : BoxFit.cover;
    final focalX = (config['focalX'] as num? ?? 0.5).toDouble();
    final focalY = (config['focalY'] as num? ?? 0.5).toDouble();
    final blur = (config['blur'] as num? ?? 0.0).toDouble();
    final scrim = (config['scrim'] as num? ?? 0.0).toDouble();
    // 槽位切换与页面组件同帧完成，不做淡入淡出；不加 key 让 gaplessPlayback 在
    // 新图尚未解码时继续显示上一张，而不是闪出底色。
    Widget image = Image(
      image: imageProvider ?? providerFor(context, config),
      fit: fit,
      gaplessPlayback: true,
      alignment: Alignment(focalX * 2 - 1, focalY * 2 - 1),
      errorBuilder: (_, __, ___) => Center(
        child: Semantics(
          label: '主题壁纸无法读取，请重新导入主题',
          child: const Icon(Icons.broken_image_outlined),
        ),
      ),
    );
    if (!isNeutralAdjustments(adjustment)) {
      image = ColorFiltered(
        colorFilter: ColorFilter.matrix(
          buildColorMatrix(
            brightness: brightness,
            contrast: contrast,
            saturation: saturation,
          ),
        ),
        child: image,
      );
    }
    if (blur > 0) {
      image = ImageFiltered(
        imageFilter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: image,
      );
    }
    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(color: background, child: image),
          if (scrim > 0) ColoredBox(color: background.withValues(alpha: scrim)),
        ],
      ),
    );
  }
}

/// 氛围背景：底色 → 线性渐变 → 径向光斑 → 平铺纹理。只用渐变和图片着色器，不做逐像素处理。
class ThemeBackdropLayer extends StatelessWidget {
  const ThemeBackdropLayer({
    super.key,
    required this.backdrop,
    required this.background,
  });

  final Map<String, dynamic> backdrop;
  final Color background;

  static Color _parse(String hex) =>
      Color(int.parse(hex.substring(1), radix: 16) | 0xFF000000);

  @override
  Widget build(BuildContext context) {
    final gradient = backdrop['gradient'] as Map?;
    final glows = (backdrop['glow'] as List?) ?? const [];
    final pattern = backdrop['pattern'] as Map?;
    LinearGradient? linear;
    if (gradient != null) {
      final colors = [for (final c in gradient['colors'] as List) _parse(c as String)];
      // angle 按 CSS 语义：0 为自下而上，90 为自左向右，180 为自上而下。
      final radians = ((gradient['angle'] as num?) ?? 180).toDouble() * 3.14159265 / 180;
      final dx = math.sin(radians);
      final dy = -math.cos(radians);
      linear = LinearGradient(
        begin: Alignment(-dx, -dy),
        end: Alignment(dx, dy),
        colors: colors,
      );
    }
    final tile = pattern?['tile'] as String?;
    return Stack(
      fit: StackFit.expand,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(color: background, gradient: linear),
        ),
        for (final raw in glows)
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: Alignment(
                  ((raw as Map)['x'] as num).toDouble() * 2 - 1,
                  (raw['y'] as num).toDouble() * 2 - 1,
                ),
                radius: (raw['radius'] as num? ?? .5).toDouble(),
                colors: [
                  _parse(raw['color'] as String)
                      .withValues(alpha: (raw['opacity'] as num? ?? .6).toDouble()),
                  _parse(raw['color'] as String).withValues(alpha: 0),
                ],
              ),
            ),
          ),
        if (tile != null)
          Opacity(
            opacity: ((pattern!['opacity'] as num?) ?? .2).toDouble(),
            child: DecoratedBox(
              decoration: BoxDecoration(
                image: DecorationImage(
                  image: FileImage(File(tile)),
                  repeat: ImageRepeat.repeat,
                  alignment: Alignment.topLeft,
                  // DecorationImage.scale 越大图越小：scale 1 时一个纹理块按 256 逻辑像素显示。
                  scale: 2 / ((pattern['scale'] as num?) ?? 1).toDouble(),
                  onError: (_, __) {},
                ),
              ),
            ),
          ),
      ],
    );
  }
}
