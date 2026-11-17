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
      final contrast = (adjustment?['contrast'] as num? ?? 100) / 100;
      final saturation = (adjustment?['saturation'] as num? ?? 100) / 100;
      final offset = brightness * 2.55 + 127.5 * (1 - contrast);
      final inverse = 1 - saturation;
      final r = .2126 * inverse * contrast;
      final g = .7152 * inverse * contrast;
      final b = .0722 * inverse * contrast;
      final physicalWidth =
          (MediaQuery.sizeOf(context).width *
                  MediaQuery.devicePixelRatioOf(context))
              .round()
              .clamp(100, 4096);
      final fit = config['fit'] == 'contain' ? BoxFit.contain : BoxFit.cover;
      final focalX = (config['focalX'] as num).toDouble();
      final focalY = (config['focalY'] as num).toDouble();
      final blur = (config['blur'] as num).toDouble();
      final scrim = (config['scrim'] as num).toDouble();
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
