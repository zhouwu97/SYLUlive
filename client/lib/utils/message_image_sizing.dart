import 'dart:math';
import 'dart:ui';

/// 私信图片气泡的展示尺寸约束与计算。
///
/// 过去所有私信图片被统一切成 210×156（4:3）导致普通竖图被裁成横图。
/// 现在按真实宽高比缩放，受最大宽高约束，不裁切、不强拉伸。

/// 计算一张 intrinsic 为 [src] 的图片应展示的像素尺寸。
///
/// - 保持真实比例（不裁切）。
/// - 大图等比缩小到 [maxWidth] × [maxHeight] 内。
/// - 太小的图不被过度缩小，视觉宽度至少 [minWidth]。
/// - 极端长图/超宽图同样缩放，不会撑满整屏。
Size constrainImageDisplaySize({
  required Size src,
  required double maxWidth,
  required double maxHeight,
  double minWidth = 96,
}) {
  if (src.width <= 0 || src.height <= 0) return Size.zero;

  // 大图等比缩小，小图保持原尺寸（不放大）。
  final scale = min(
    1.0,
    min(maxWidth / src.width, maxHeight / src.height),
  );
  var width = src.width * scale;
  var height = src.height * scale;

  // 极小图：放大到至少 minWidth 视觉宽度（上限仍受 maxHeight 约束）。
  if (width < minWidth && height < maxHeight) {
    final upscale = min(minWidth / width, maxHeight / height);
    width *= upscale;
    height *= upscale;
  }

  // 极端比例（长截图 / 超宽图）最终再限幅，严格落在约束内。
  if (width > maxWidth || height > maxHeight) {
    final finalScale = min(maxWidth / width, maxHeight / height);
    width *= finalScale;
    height *= finalScale;
  }

  return Size(width, height);
}
