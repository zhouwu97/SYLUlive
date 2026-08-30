import '../config/api_constants.dart';

/// 食堂图片的网络变体。
///
/// 服务端会为 /uploads 下的图片生成固定尺寸的 JPEG 变体。页面只需要声明
/// 使用场景，不应该自行拼接文件名后缀，以免破坏 CDN 查询参数或外部图片地址。
enum CanteenImageVariant {
  thumb,
  medium,
  original;

  String get suffix => switch (this) {
        CanteenImageVariant.thumb => '_v1_thumb',
        CanteenImageVariant.medium => '_v1_medium',
        CanteenImageVariant.original => '',
      };

  static CanteenImageVariant? fromName(String value) {
    return switch (value.trim().toLowerCase()) {
      'thumb' => CanteenImageVariant.thumb,
      'medium' => CanteenImageVariant.medium,
      'original' => CanteenImageVariant.original,
      _ => null,
    };
  }
}

/// 将食堂图片源地址解析为适合当前场景的 URL。
///
/// 只有 /uploads/ 下的服务端资源会生成变体；外部 CDN、无扩展名资源和空地址
/// 均保留原地址。已经带有版本化或旧式变体后缀的地址会先剥离后缀。
String canteenImageUrl(
  String source, {
  CanteenImageVariant variant = CanteenImageVariant.original,
}) {
  final originalUrl = ApiConstants.fullUrl(source);
  if (originalUrl.isEmpty || variant == CanteenImageVariant.original) {
    return originalUrl;
  }

  final uri = Uri.tryParse(originalUrl);
  if (uri == null || !uri.path.contains('/uploads/')) {
    return originalUrl;
  }

  final slashIndex = uri.path.lastIndexOf('/');
  final dotIndex = uri.path.lastIndexOf('.');
  if (dotIndex <= slashIndex) return originalUrl;

  final extension = uri.path.substring(dotIndex);
  final basePath = uri.path.substring(0, dotIndex).replaceFirst(
        RegExp(r'_(?:v\d+_)?(?:thumb|medium)$'),
        '',
      );
  return ApiConstants.fullUrl(
    uri.replace(path: '$basePath${variant.suffix}$extension').toString(),
  );
}
