import 'dart:async';

import 'package:flutter/material.dart';

import '../../config/api_constants.dart';
import '../../screens/image_viewer_screen.dart';
import '../../services/diagnostic_log_service.dart';
import '../../theme/app_colors.dart';
import '../../utils/canteen_pending_image_cache.dart';
import '../app_cached_image.dart';

/// 管理员审核食堂门面图专用的私有图片加载组件。
///
/// 核心特性：
/// 1. 强制走 `AppCachedImage.private` 鉴权通道，携带管理员 Bearer JWT；
/// 2. 使用独立的 [CanteenPendingImageCache]，禁止与公开帖子图片缓存混用；
/// 3. 直接请求原始待审核 URL，不依赖未生成的公开 thumb 变体；
/// 4. 适配超大图与多格式：设置 `memCacheWidth: 720` / `memCacheHeight: 405` 避免原图撑爆内存；
/// 5. 点击通过 [ImageViewerScreen] 全屏查看，透传相同的鉴权头、缓存管理器和账号隔离 CacheKey；
/// 6. 完善的空态、加载态与可重试失败态，并在失败时记录诊断日志（绝不记录 token）。
class CanteenPendingReviewImage extends StatefulWidget {
  final String? imageUrl;
  final int? canteenId;
  final String? token;
  final int? accountId;
  final double? width;
  final double? height;
  final BoxFit fit;
  final BorderRadius? borderRadius;
  final bool enableViewer;
  final VoidCallback? onTap;

  const CanteenPendingReviewImage({
    super.key,
    required this.imageUrl,
    this.canteenId,
    this.token,
    this.accountId,
    this.width = double.infinity,
    this.height = 175,
    this.fit = BoxFit.cover,
    this.borderRadius,
    this.enableViewer = true,
    this.onTap,
  });

  @override
  State<CanteenPendingReviewImage> createState() =>
      _CanteenPendingReviewImageState();
}

class _CanteenPendingReviewImageState extends State<CanteenPendingReviewImage> {
  int _retryNonce = 0;

  void _handleRetry(String fullUrl) {
    unawaited(() async {
      try {
        final cacheKey = CanteenPendingImageCache.cacheKeyFor(
          fullUrl,
          accountId: widget.accountId,
        );
        await CanteenPendingImageCache.instance.manager.removeFile(cacheKey);
      } catch (_) {}
      if (mounted) {
        setState(() {
          _retryNonce++;
        });
      }
    }());
  }

  void _recordDiagnosticFailure(String fullUrl, Object error) {
    DiagnosticLogService.instance.record(
      level: 'warn',
      source: 'CanteenPendingReviewImage',
      type: 'pending_image_load_failed',
      summary: '待审核食堂门面图加载失败',
      detail:
          'canteen_id=${widget.canteenId ?? 0} url=$fullUrl error=$error auth_provided=${widget.token != null && widget.token!.isNotEmpty}',
      category: 'canteen_admin',
      operation: 'load_pending_canteen_image',
      result: 'failed',
    );
  }

  void _openFullscreenViewer(BuildContext context, String fullUrl) {
    if (widget.onTap != null) {
      widget.onTap!();
      return;
    }
    if (!widget.enableViewer) return;

    final token = widget.token;
    final accountId = widget.accountId;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ImageViewerScreen(
          imageUrls: [fullUrl],
          initialIndex: 0,
          httpHeaders: (token != null && token.isNotEmpty)
              ? {'Authorization': 'Bearer $token'}
              : const {},
          cacheManager: CanteenPendingImageCache.instance.manager,
          cacheKeyBuilder: (url) => CanteenPendingImageCache.cacheKeyFor(
            url,
            accountId: accountId,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final rawUrl = widget.imageUrl?.trim() ?? '';

    if (rawUrl.isEmpty) {
      return _buildEmptyContainer(isDark);
    }

    final fullUrl = ApiConstants.fullUrl(rawUrl);
    final token = widget.token;
    final authHeaders = (token != null && token.isNotEmpty)
        ? {'Authorization': 'Bearer $token'}
        : const <String, String>{};
    final cacheKey = CanteenPendingImageCache.cacheKeyFor(
      fullUrl,
      accountId: widget.accountId,
    );

    Widget imageContent = KeyedSubtree(
      key: ValueKey('pending_img_${fullUrl}_$_retryNonce'),
      child: AppCachedImage.private(
        imageUrl: fullUrl,
        cacheManager: CanteenPendingImageCache.instance.manager,
        cacheKey: cacheKey,
        httpHeaders: authHeaders,
        width: widget.width,
        height: widget.height,
        fit: widget.fit,
        memCacheWidth: 720,
        memCacheHeight: 405,
        placeholder: (context, _) => _buildLoadingContainer(isDark),
        errorWidget: (context, url, error) {
          _recordDiagnosticFailure(fullUrl, error);
          return _buildErrorContainer(isDark, fullUrl);
        },
      ),
    );

    if (widget.borderRadius != null) {
      imageContent = ClipRRect(
        borderRadius: widget.borderRadius!,
        child: imageContent,
      );
    }

    return GestureDetector(
      onTap: () => _openFullscreenViewer(context, fullUrl),
      child: Stack(
        children: [
          imageContent,
          // 悬浮全屏预览轻量角标提示
          Positioned(
            right: 8,
            bottom: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.fullscreen_rounded,
                    color: Colors.white,
                    size: 14,
                  ),
                  SizedBox(width: 3),
                  Text(
                    '查看大图',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoadingContainer(bool isDark) {
    return Container(
      width: widget.width,
      height: widget.height,
      color: isDark ? const Color(0xFF1E2226) : const Color(0xFFF1F5F2),
      child: const Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(
            strokeWidth: 2.5,
            color: AppColors.brandPrimary,
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyContainer(bool isDark) {
    Widget content = Container(
      width: widget.width,
      height: widget.height,
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E2226) : const Color(0xFFF4F6F4),
        borderRadius: widget.borderRadius,
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.storefront_outlined,
            size: 36,
            color: isDark ? Colors.white38 : const Color(0xFF9AA6A0),
          ),
          const SizedBox(height: 6),
          Text(
            '未上传门面图',
            style: TextStyle(
              fontSize: 13,
              color: isDark ? Colors.white54 : const Color(0xFF7B8882),
            ),
          ),
        ],
      ),
    );

    if (widget.borderRadius != null) {
      content = ClipRRect(
        borderRadius: widget.borderRadius!,
        child: content,
      );
    }
    return content;
  }

  Widget _buildErrorContainer(bool isDark, String fullUrl) {
    return Container(
      width: widget.width,
      height: widget.height,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      color: isDark ? const Color(0xFF261D1D) : const Color(0xFFFDF2F2),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.broken_image_outlined,
              size: 32,
              color: isDark ? const Color(0xFFE57373) : const Color(0xFFD32F2F),
            ),
            const SizedBox(height: 6),
            Text(
              '门面图加载失败',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: isDark
                    ? const Color(0xFFEF9A9A)
                    : const Color(0xFFC62828),
              ),
            ),
            const SizedBox(height: 8),
            InkWell(
              onTap: () => _handleRetry(fullUrl),
              borderRadius: BorderRadius.circular(12),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                decoration: BoxDecoration(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.1)
                      : Colors.white,
                  border: Border.all(
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.2)
                        : const Color(0xFFE0B4B4),
                  ),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.refresh_rounded,
                      size: 14,
                      color: isDark ? Colors.white70 : const Color(0xFF555555),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '重新加载',
                      style: TextStyle(
                        fontSize: 12,
                        color:
                            isDark ? Colors.white70 : const Color(0xFF444444),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
