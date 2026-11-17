import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../theme/app_theme_tokens.dart';

class ThemedWallpaperLayer extends StatelessWidget {
  const ThemedWallpaperLayer(
      {super.key, required this.settings, this.imageProvider});
  final Map<String, dynamic>? settings;
  final ImageProvider? imageProvider;

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

  @override
  Widget build(BuildContext context) {
    final config = settings;
    final background = AppThemeTokens.of(context).background;
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    final duration =
        disableAnimations ? Duration.zero : const Duration(milliseconds: 200);
    Widget content;
    if (config == null) {
      content = ColoredBox(
        key: ValueKey(('solid', background)),
        color: background,
      );
    } else {
      final landscape =
          MediaQuery.orientationOf(context) == Orientation.landscape;
      final file =
          (landscape ? config['landscape'] : null) ?? config['portrait'];
      final adjustment = config['adjustments'] as Map?;
      final brightness = (adjustment?['brightness'] as num? ?? 0).toDouble();
      final contrast = (adjustment?['contrast'] as num? ?? 100).toDouble();
      final saturation = (adjustment?['saturation'] as num? ?? 100).toDouble();
      final physicalWidth =
          (MediaQuery.sizeOf(context).width *
                  MediaQuery.devicePixelRatioOf(context))
              .round()
              .clamp(100, 4096);
      final fit = config['fit'] == 'contain' ? BoxFit.contain : BoxFit.cover;
      final focalX = (config['focalX'] as num? ?? 0.5).toDouble();
      final focalY = (config['focalY'] as num? ?? 0.5).toDouble();
      final blur = (config['blur'] as num? ?? 0.0).toDouble();
      final scrim = (config['scrim'] as num? ?? 0.0).toDouble();
      Widget image = Image(
        key: ValueKey(file),
        image: imageProvider ??
            ResizeImage(
              FileImage(File(file as String)),
              width: physicalWidth,
              policy: ResizeImagePolicy.fit,
              allowUpscaling: false,
            ),
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
      content = ClipRect(
        key: ValueKey((
          file,
          fit,
          focalX,
          focalY,
          blur,
          scrim,
          brightness,
          contrast,
          saturation,
        )),
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: background, child: image),
            if (scrim > 0)
              ColoredBox(color: background.withValues(alpha: scrim)),
          ],
        ),
      );
    }
    return AnimatedSwitcher(
      duration: duration,
      child: content,
    );
  }
}
