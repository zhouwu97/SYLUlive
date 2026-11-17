import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../theme/app_theme_tokens.dart';

class ThemedWallpaperLayer extends StatelessWidget {
  const ThemedWallpaperLayer(
      {super.key, required this.settings, this.imageProvider});
  final Map<String, dynamic>? settings;
  final ImageProvider? imageProvider;

  @override
  Widget build(BuildContext context) {
    final config = settings;
    final background = AppThemeTokens.of(context).background;
    if (config == null) return ColoredBox(color: background);
    final landscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final file = (landscape ? config['landscape'] : null) ?? config['portrait'];
    final adjustment = config['adjustments'] as Map?;
    final contrast = (adjustment?['contrast'] as num? ?? 100) / 100;
    final saturation = (adjustment?['saturation'] as num? ?? 100) / 100;
    final offset = (adjustment?['brightness'] as num? ?? 0) * 2.55 +
        127.5 * (1 - contrast);
    final inverse = 1 - saturation;
    final r = .2126 * inverse * contrast;
    final g = .7152 * inverse * contrast;
    final b = .0722 * inverse * contrast;
    Widget image = Image(
      key: ValueKey(file),
      image: imageProvider ??
          ResizeImage(FileImage(File(file as String)),
              width: 2160,
              height: 2160,
              policy: ResizeImagePolicy.fit,
              allowUpscaling: false),
      fit: config['fit'] == 'contain' ? BoxFit.contain : BoxFit.cover,
      alignment: Alignment((config['focalX'] as num).toDouble() * 2 - 1,
          (config['focalY'] as num).toDouble() * 2 - 1),
      errorBuilder: (_, __, ___) => Center(
          child: Semantics(
        label: '主题壁纸无法读取，请重新导入主题',
        child: const Icon(Icons.broken_image_outlined),
      )),
    );
    if (adjustment != null) {
      image = ColorFiltered(
          colorFilter: ColorFilter.matrix([
            r + saturation * contrast,
            g,
            b,
            0,
            offset,
            r,
            g + saturation * contrast,
            b,
            0,
            offset,
            r,
            g,
            b + saturation * contrast,
            0,
            offset,
            0,
            0,
            0,
            1,
            0,
          ]),
          child: image);
    }
    final blur = (config['blur'] as num).toDouble();
    if (blur > 0) {
      image = ImageFiltered(
          imageFilter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: image);
    }
    final scrim = (config['scrim'] as num).toDouble();
    return ClipRect(
        child: Stack(fit: StackFit.expand, children: [
      ColoredBox(color: background, child: image),
      if (scrim > 0)
        ColoredBox(
            color: (Theme.of(context).brightness == Brightness.dark
                    ? Colors.black
                    : Colors.white)
                .withValues(alpha: scrim)),
    ]));
  }
}
