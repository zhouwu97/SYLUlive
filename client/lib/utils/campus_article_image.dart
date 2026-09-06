import 'dart:math' as math;

import '../config/api_constants.dart';
import 'image_decode_size.dart';

/// 校园文章图片在客户端的候选资源档位。
enum CampusArticleImageVariant { original, thumb, medium, viewer }

/// 一条文章图片候选地址及其解码策略。
class CampusArticleImageCandidate {
  const CampusArticleImageCandidate({
    required this.url,
    required this.variant,
  });

  final String url;
  final CampusArticleImageVariant variant;

  bool get shouldResize {
    if (variant != CampusArticleImageVariant.original) return true;
    return !_isGifUrl(url);
  }
}

/// 将正文中的图片 URL 解析为本站变体候选。
///
/// 只有本站 `/uploads/` 资源生成变体；学校官网或其他外部图片保持原地址。
/// 文章接口没有随 HTML 返回变体状态，因此正文按候选顺序尝试，并在变体
/// 不存在时回退到原图；全屏查看器则由调用方决定是否允许自动加载原图。
class CampusArticleImageResources {
  CampusArticleImageResources._({
    required this.originalUrl,
    required this.isManagedUpload,
    this.thumbUrl,
    this.mediumUrl,
    this.viewerUrl,
  });

  factory CampusArticleImageResources.fromUri(Uri uri) {
    final originalUrl = ApiConstants.fullUrl(uri.toString());
    final managed = _isManagedUpload(uri);
    if (!managed || originalUrl.isEmpty) {
      return CampusArticleImageResources._(
        originalUrl: originalUrl,
        isManagedUpload: false,
      );
    }

    return CampusArticleImageResources._(
      originalUrl: originalUrl,
      isManagedUpload: true,
      thumbUrl: _variantUrl(originalUrl, 'thumb'),
      mediumUrl: _variantUrl(originalUrl, 'medium'),
      viewerUrl: _variantUrl(originalUrl, 'viewer'),
    );
  }

  final String originalUrl;
  final bool isManagedUpload;
  final String? thumbUrl;
  final String? mediumUrl;
  final String? viewerUrl;

  /// 根据当前展示尺寸返回从优先到兜底的候选地址。
  List<CampusArticleImageCandidate> candidatesFor(ImageDecodeTarget target) {
    if (!isManagedUpload) {
      return [
        CampusArticleImageCandidate(
          url: originalUrl,
          variant: CampusArticleImageVariant.original,
        ),
      ];
    }

    final variants = target.longEdge <= imageThumbLongEdge
        ? const [
            CampusArticleImageVariant.thumb,
            CampusArticleImageVariant.medium,
            CampusArticleImageVariant.viewer,
          ]
        : target.longEdge <= imageMediumLongEdge
            ? const [
                CampusArticleImageVariant.medium,
                CampusArticleImageVariant.thumb,
                CampusArticleImageVariant.viewer,
              ]
            : const [
                CampusArticleImageVariant.viewer,
                CampusArticleImageVariant.medium,
                CampusArticleImageVariant.thumb,
              ];

    final candidates = <CampusArticleImageCandidate>[];
    for (final variant in variants) {
      final url = _urlFor(variant);
      if (url == null || url.isEmpty || url == originalUrl) continue;
      if (candidates.any((candidate) => candidate.url == url)) continue;
      candidates.add(
        CampusArticleImageCandidate(url: url, variant: variant),
      );
    }
    if (originalUrl.isNotEmpty &&
        !candidates.any((candidate) => candidate.url == originalUrl)) {
      candidates.add(
        CampusArticleImageCandidate(
          url: originalUrl,
          variant: CampusArticleImageVariant.original,
        ),
      );
    }
    return candidates;
  }

  String? _urlFor(CampusArticleImageVariant variant) {
    return switch (variant) {
      CampusArticleImageVariant.original => originalUrl,
      CampusArticleImageVariant.thumb => thumbUrl,
      CampusArticleImageVariant.medium => mediumUrl,
      CampusArticleImageVariant.viewer => viewerUrl,
    };
  }
}

String? _variantUrl(String originalUrl, String variant) {
  final generated = ApiConstants.imageVariant(originalUrl, variant);
  return generated.isEmpty || generated == originalUrl ? null : generated;
}

bool _isManagedUpload(Uri uri) {
  final path = uri.path;
  if (!path.startsWith('/uploads/')) return false;

  // 相对 /uploads/ 路径由 ApiConstants.fullUrl 解析到当前应用，直接视为本站资源。
  if (!uri.hasScheme) return true;

  final configuredRoot = Uri.tryParse(
    ApiConstants.apiRootFromBaseUrl(ApiConstants.baseUrl),
  );
  if (configuredRoot == null ||
      !configuredRoot.hasScheme ||
      configuredRoot.host.isEmpty) {
    // Web 默认使用相对 API 根（/api），此时从配置无法推导绝对本站地址；
    // 使用运行时页面 origin 识别同源上传图片，避免绝对 /uploads/ URL 漏掉变体。
    final runtimeOrigin = Uri.base;
    if (!runtimeOrigin.hasScheme || runtimeOrigin.host.isEmpty) return false;
    return uri.host.toLowerCase() == runtimeOrigin.host.toLowerCase() &&
        _effectivePort(uri) == _effectivePort(runtimeOrigin);
  }
  return uri.host.toLowerCase() == configuredRoot.host.toLowerCase() &&
      _effectivePort(uri) == _effectivePort(configuredRoot);
}

int _effectivePort(Uri uri) {
  if (uri.hasPort) return uri.port;
  return uri.scheme.toLowerCase() == 'http' ? 80 : 443;
}

bool _isGifUrl(String url) {
  final uri = Uri.tryParse(url);
  final path = uri?.path ?? url.split('?').first;
  return path.toLowerCase().endsWith('.gif');
}

/// 测试和调用方可用的 URL 变体判断，避免复制 GIF 后缀逻辑。
bool isCampusArticleGifUrl(String url) => _isGifUrl(url);

/// 文章图片候选最多只需覆盖查看器上限，避免异常尺寸导致无界整数。
int clampCampusArticleDecodeLongEdge(int value) {
  return math.max(1, math.min(value, imageViewerLongEdge));
}
