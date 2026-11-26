import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:material_color_utilities/material_color_utilities.dart';

/// 主题视觉 V2 的附加参数：识别色协调、区块记号、状态插画和标题字体。
///
/// 默认值全部为"不生效"，没有应用主题时外观与原来完全一致。
class AppThemeStyle extends ThemeExtension<AppThemeStyle> {
  const AppThemeStyle({
    this.identityHarmony = 0,
    this.identityAnchor,
    this.sectionMark = 'none',
    this.sectionMarkImage,
    this.emptyIllustration,
    this.errorIllustration,
    this.titleFontFamily,
    this.ornaments = const {},
    this.serviceIcons = const {},
    this.cardArt,
  });

  /// 0–1；识别色向 [identityAnchor] 色相靠拢的强度。
  final double identityHarmony;

  /// 协调目标色，取主题的 primary。
  final Color? identityAnchor;

  /// none / dot / bar / icon。
  final String sectionMark;

  /// sectionMark 为 icon 时的本地图片路径。
  final String? sectionMarkImage;
  final String? emptyIllustration;
  final String? errorIllustration;
  final String? titleFontFamily;

  /// 卡片角饰，键为 postCard／campusHeader／campusNotice／campusServices／fab。
  final Map<String, ThemeOrnamentSpec> ornaments;

  /// 校园服务图标的本地图片路径，键为 edu／canteen／ranking／team／map／calendar。
  final Map<String, String> serviceIcons;

  /// 内容卡片里的淡底图；null 表示不画。
  final ThemeCardArtSpec? cardArt;

  static AppThemeStyle of(BuildContext context) =>
      Theme.of(context).extension<AppThemeStyle>() ?? const AppThemeStyle();

  /// 把分类图标、板块识别色向主题色相协调；状态色（成功、警告、危险）不能调用这里。
  Color identity(Color color) {
    final anchor = identityAnchor;
    if (identityHarmony <= 0 || anchor == null) return color;
    final source = Hct.fromInt(color.toARGB32());
    final target = Hct.fromInt(anchor.toARGB32());
    final diff = ((target.hue - source.hue + 540) % 360) - 180;
    final rotation =
        diff.sign * math.min(diff.abs() * 0.6, 40.0) * identityHarmony;
    final harmonized = Hct.from(
      (source.hue + rotation + 360) % 360,
      source.chroma * (1 - 0.35 * identityHarmony),
      source.tone,
    );
    return Color(harmonized.toInt()).withValues(alpha: color.a);
  }

  /// 页头、区块标题等展示性文字使用主题的标题字体；没有标题字体时原样返回。
  ///
  /// 展示字体多数只有常规字重，16 号以下再叠加粗体会糊，所以小字号保持正文字体。
  TextStyle title(TextStyle style) =>
      titleFontFamily == null || (style.fontSize ?? 14) < 16
          ? style
          : style.copyWith(fontFamily: titleFontFamily);

  ImageProvider? imageFor(String? path) =>
      path == null || path.isEmpty ? null : FileImage(File(path));

  /// 主题为 [key] 提供的服务／工具图标；没有时返回 null，调用方用原 Icon。
  Widget? serviceIcon(BuildContext context, String? key, {double size = 40}) {
    final provider = imageFor(serviceIcons[key]);
    if (provider == null) return null;
    return Image(
      key: ValueKey('theme-service-icon-$key'),
      image: ResizeImage(
        provider,
        width: (size * MediaQuery.devicePixelRatioOf(context)).round(),
        policy: ResizeImagePolicy.fit,
      ),
      width: size,
      height: size,
      fit: BoxFit.contain,
      errorBuilder: (_, __, ___) => SizedBox(width: size, height: size),
    );
  }

  @override
  AppThemeStyle copyWith({
    double? identityHarmony,
    Color? identityAnchor,
    String? sectionMark,
    String? sectionMarkImage,
    String? emptyIllustration,
    String? errorIllustration,
    String? titleFontFamily,
    Map<String, ThemeOrnamentSpec>? ornaments,
    Map<String, String>? serviceIcons,
    ThemeCardArtSpec? cardArt,
  }) =>
      AppThemeStyle(
        identityHarmony: identityHarmony ?? this.identityHarmony,
        identityAnchor: identityAnchor ?? this.identityAnchor,
        sectionMark: sectionMark ?? this.sectionMark,
        sectionMarkImage: sectionMarkImage ?? this.sectionMarkImage,
        emptyIllustration: emptyIllustration ?? this.emptyIllustration,
        errorIllustration: errorIllustration ?? this.errorIllustration,
        titleFontFamily: titleFontFamily ?? this.titleFontFamily,
        ornaments: ornaments ?? this.ornaments,
        serviceIcons: serviceIcons ?? this.serviceIcons,
        cardArt: cardArt ?? this.cardArt,
      );

  @override
  AppThemeStyle lerp(covariant AppThemeStyle? other, double t) =>
      other == null || t < 0.5 ? this : other;
}

/// 内容卡片淡底图参数，含义见格式契约 2.10。
class ThemeCardArtSpec {
  const ThemeCardArtSpec({
    required this.image,
    this.alignment = 'bottomRight',
    this.width = .42,
    this.opacity = .14,
  });

  factory ThemeCardArtSpec.fromJson(Map value) => ThemeCardArtSpec(
        image: value['image'] as String,
        alignment: value['alignment'] as String? ?? 'bottomRight',
        width: (value['width'] as num? ?? .42).toDouble(),
        opacity: (value['opacity'] as num? ?? .14).toDouble(),
      );

  final String image;
  final String alignment;

  /// 占卡片宽度的比例，最宽 200 逻辑像素。
  final double width;
  final double opacity;

  Alignment get resolvedAlignment => switch (alignment) {
        'bottomLeft' => Alignment.bottomLeft,
        'topRight' => Alignment.topRight,
        'topLeft' => Alignment.topLeft,
        _ => Alignment.bottomRight,
      };
}

/// 卡片淡底图：铺在卡片内容后面，按卡片宽度缩放，不响应点击、不进语义树；矮于 48 的面板不画。
class ThemeCardArt extends StatelessWidget {
  const ThemeCardArt({super.key, required this.spec});

  final ThemeCardArtSpec spec;

  @override
  Widget build(BuildContext context) {
    final provider = AppThemeStyle.of(context).imageFor(spec.image);
    if (provider == null) return const SizedBox.shrink();
    return IgnorePointer(
      child: ExcludeSemantics(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = (constraints.maxWidth * spec.width).clamp(0.0, 200.0);
            if (width < 64 || constraints.maxHeight < 48) {
              return const SizedBox.shrink();
            }
            return Align(
              alignment: spec.resolvedAlignment,
              child: Image(
                image: ResizeImage(
                  provider,
                  width:
                      (width * MediaQuery.devicePixelRatioOf(context)).round(),
                  policy: ResizeImagePolicy.fit,
                ),
                width: width,
                height: constraints.maxHeight,
                fit: BoxFit.contain,
                alignment: spec.resolvedAlignment,
                opacity: AlwaysStoppedAnimation(spec.opacity),
                errorBuilder: (_, __, ___) => const SizedBox.shrink(),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// 卡片角饰参数，含义见格式契约 2.10。
class ThemeOrnamentSpec {
  const ThemeOrnamentSpec({
    required this.image,
    this.corner = 'topRight',
    required this.width,
    this.dx = 0,
    this.dy = 0,
    this.opacity = 1,
  });

  factory ThemeOrnamentSpec.fromJson(Map value) => ThemeOrnamentSpec(
        image: value['image'] as String,
        corner: value['corner'] as String? ?? 'topRight',
        width: (value['width'] as num).toDouble(),
        dx: (value['dx'] as num? ?? 0).toDouble(),
        dy: (value['dy'] as num? ?? 0).toDouble(),
        opacity: (value['opacity'] as num? ?? 1).toDouble(),
      );

  final String image;
  final String corner;
  final double width;
  final double dx;
  final double dy;
  final double opacity;
}

/// 给卡片挂上主题角饰：不占布局、不响应点击、不进语义树；没有配置时原样返回 [child]。
class ThemeOrnamented extends StatelessWidget {
  const ThemeOrnamented({super.key, required this.slot, required this.child});

  final String slot;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final style = AppThemeStyle.of(context);
    final spec = style.ornaments[slot];
    final provider = style.imageFor(spec?.image);
    if (spec == null || provider == null) return child;
    final top = spec.corner.startsWith('top');
    final left = spec.corner.endsWith('Left');
    final art = Image(
      image: ResizeImage(
        provider,
        width: (spec.width * MediaQuery.devicePixelRatioOf(context)).round(),
        policy: ResizeImagePolicy.fit,
      ),
      width: spec.width,
      fit: BoxFit.contain,
      alignment: Alignment(left ? -1 : 1, top ? 1 : -1),
      opacity: spec.opacity < 1 ? AlwaysStoppedAnimation(spec.opacity) : null,
      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
    );
    return Stack(
      clipBehavior: Clip.none,
      children: [
        child,
        Positioned(
          key: ValueKey('theme-ornament-$slot'),
          top: top ? spec.dy : null,
          bottom: top ? null : spec.dy,
          left: left ? spec.dx : null,
          right: left ? null : spec.dx,
          child: IgnorePointer(child: ExcludeSemantics(child: art)),
        ),
      ],
    );
  }
}

/// 区块标题前的主题记号；样式为 none 时不占位。
class ThemeSectionMark extends StatelessWidget {
  const ThemeSectionMark({super.key, required this.color, this.size = 16});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final style = AppThemeStyle.of(context);
    final Widget mark = switch (style.sectionMark) {
      'dot' => Container(
          width: size * 0.45,
          height: size * 0.45,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
      'bar' => Container(
          width: 4,
          height: size,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      'icon' => style.imageFor(style.sectionMarkImage) == null
          ? const SizedBox.shrink()
          : ColorFiltered(
              colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
              child: Image(
                image: ResizeImage(
                  style.imageFor(style.sectionMarkImage)!,
                  width: (size * MediaQuery.devicePixelRatioOf(context))
                      .round()
                      .clamp(16, 96),
                ),
                width: size,
                height: size,
                errorBuilder: (_, __, ___) => const SizedBox.shrink(),
              ),
            ),
      _ => const SizedBox.shrink(),
    };
    if (style.sectionMark == 'none') return const SizedBox.shrink();
    return ExcludeSemantics(
      child: Padding(
        padding: const EdgeInsets.only(right: 7),
        child: mark,
      ),
    );
  }
}

/// 区块标题：主题记号 + 标题字体。没有应用主题时等同于原来的 Text。
class ThemeSectionTitle extends StatelessWidget {
  const ThemeSectionTitle(this.text,
      {super.key, required this.style, this.markColor});

  final String text;
  final TextStyle style;

  /// 记号颜色，默认取主题主色。
  final Color? markColor;

  @override
  Widget build(BuildContext context) {
    final theme = AppThemeStyle.of(context);
    final label = Text(text, style: theme.title(style));
    if (theme.sectionMark == 'none') return label;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ThemeSectionMark(
          color: markColor ?? Theme.of(context).colorScheme.primary,
          size: (style.fontSize ?? 16) * 0.95,
        ),
        Flexible(child: label),
      ],
    );
  }
}

/// 空状态、错误状态的图标位：主题提供插画时显示插画，否则显示 [fallback]。
class ThemeStateArt extends StatelessWidget {
  const ThemeStateArt({
    super.key,
    required this.fallback,
    this.error = false,
    this.size = 120,
    this.enabled = true,
  });

  final Widget fallback;
  final bool error;
  final double size;

  /// 加载态等不应替换的场景传 false。
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    if (!enabled) return fallback;
    final style = AppThemeStyle.of(context);
    final path = error ? style.errorIllustration : style.emptyIllustration;
    final provider = style.imageFor(path);
    if (provider == null) return fallback;
    return ExcludeSemantics(
      child: Image(
        key: ValueKey('theme-state-art-${error ? 'error' : 'empty'}'),
        image: ResizeImage(
          provider,
          width: (size * MediaQuery.devicePixelRatioOf(context))
              .round()
              .clamp(64, 800),
        ),
        width: size,
        height: size,
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => fallback,
      ),
    );
  }
}
