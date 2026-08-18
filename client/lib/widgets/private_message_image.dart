import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../config/api_constants.dart';
import '../services/diagnostic_log_service.dart';
import '../utils/image_header_size_parser.dart';
import '../utils/message_image_sizing.dart';
import '../utils/private_message_media_cache.dart';

/// 私信图片独立渲染组件。
///
/// - 按真实宽高比展示，不统一裁成 4:3。
/// - 数据来源优先级：本地文件 → 带鉴权的网络 → 可重试失败态。
/// - 失败时展示中性失败卡（surfaceContainer/outlineVariant/onSurfaceVariant，
///   不用发送方 primary 紫色），点击重新加载（evict 缓存后重新拉取）。
/// - 失败记录 pm_media_* 诊断日志，便于定位坏图。
class PrivateMessageImage extends StatefulWidget {
  /// 鉴权后的下载 URL（如 /api/messages/files/{id}）。为空表示没有网络来源。
  final String? networkUrl;

  /// 发送方刚发完仍存在的本地文件路径。
  final String? localPath;

  /// 服务端返回的规范宽高；为 0 时回退到本地解码的 intrinsic 尺寸。
  final int serverWidth;
  final int serverHeight;

  final int? fileId;

  final Map<String, String> httpHeaders;

  /// 账号作用域 ID；为空时默认使用 [PrivateMessageMediaCache.instance.accountId]。
  final int? accountId;

  /// 自定义缓存 key；为空时由 [PrivateMessageMediaCache.cacheKeyFor] 自动生成账号作用域 key。
  final String? cacheKey;

  /// 私信媒体缓存；为空时使用账号作用域的 [PrivateMessageMediaCache]。
  final CacheManager? cacheManager;
  final double maxWidth;
  final double maxHeight;
  final double minWidth;

  /// 点击失败卡触发的重新加载；为空时仅重新解码/重新请求当前来源。
  final VoidCallback? onRetry;

  const PrivateMessageImage({
    super.key,
    this.networkUrl,
    this.localPath,
    this.serverWidth = 0,
    this.serverHeight = 0,
    this.httpHeaders = const <String, String>{},
    this.fileId,
    this.accountId,
    this.cacheKey,
    this.maxWidth = 260,
    this.maxHeight = 320,
    this.minWidth = 96,
    this.cacheManager,
    this.onRetry,
  });

  @override
  State<PrivateMessageImage> createState() => _PrivateMessageImageState();
}

class _PrivateMessageImageState extends State<PrivateMessageImage> {
  Size? _intrinsic;
  bool _localFailed = false;
  int _loadAttempt = 0;

  @override
  void initState() {
    super.initState();
    _resolveIntrinsic();
  }

  @override
  void didUpdateWidget(covariant PrivateMessageImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.localPath != widget.localPath ||
        oldWidget.networkUrl != widget.networkUrl ||
        oldWidget.serverWidth != widget.serverWidth ||
        oldWidget.serverHeight != widget.serverHeight) {
      _intrinsic = null;
      _localFailed = false;
      _resolveIntrinsic();
    }
  }

  /// 服务端没给宽高时，使用轻量级文件头解析器提取尺寸，不将整图读入内存。
  Future<void> _resolveIntrinsic() async {
    if (widget.serverWidth > 0 && widget.serverHeight > 0) return;
    final localPath = widget.localPath;
    if (localPath == null || localPath.isEmpty) return;
    try {
      final size = await ImageHeaderSizeParser.parseFileSize(localPath);
      if (!mounted || size == null || size.width <= 0 || size.height <= 0) {
        return;
      }
      setState(() => _intrinsic = size);
    } catch (_) {
      // 本地文件解码失败，交由渲染层回退到网络来源。
    }
  }

  Size? get _sourceSize {
    if (widget.serverWidth > 0 && widget.serverHeight > 0) {
      return Size(
        widget.serverWidth.toDouble(),
        widget.serverHeight.toDouble(),
      );
    }
    return _intrinsic;
  }

  Size? get _displaySize {
    final source = _sourceSize;
    if (source == null) return null;
    final size = constrainImageDisplaySize(
      src: source,
      maxWidth: widget.maxWidth,
      maxHeight: widget.maxHeight,
      minWidth: widget.minWidth,
    );
    return size.width <= 0 ? null : size;
  }

  void _logFailure(String type, {int? httpStatus, bool hasLocal = false}) {
    DiagnosticLogService.instance.record(
      level: 'error',
      source: 'pm_image',
      type: type,
      eventCode: type,
      category: 'pm',
      summary: '私信图片加载失败',
      detail: 'url=${widget.networkUrl ?? '-'} fileId=${widget.fileId ?? '-'} '
          'local=${widget.localPath != null}',
      httpStatus: httpStatus,
      route: 'chat_detail',
      metadata: {
        'fileId': widget.fileId ?? -1,
        'hasLocalFallback': hasLocal,
        'attempt': _loadAttempt,
      },
    );
  }

  Future<void> _retry() async {
    final url = widget.networkUrl;
    if (url != null && url.isNotEmpty) {
      final fullUrl = ApiConstants.fullUrl(url);
      final key = widget.cacheKey ??
          PrivateMessageMediaCache.cacheKeyFor(
            fullUrl,
            accountId: widget.accountId,
          );
      try {
        await (widget.cacheManager ?? PrivateMessageMediaCache.instance.manager)
            .removeFile(key);
      } catch (_) {}
    }

    if (!mounted) return;

    setState(() {
      _loadAttempt++;
      _localFailed = false;
    });
    widget.onRetry?.call();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final display = _displaySize;

    // 来源：本地优先，失败回退到网络。
    final localPath = widget.localPath;
    final networkUrl = widget.networkUrl;

    Widget? imageContent;
    final showLocal =
        localPath != null && localPath.isNotEmpty && !_localFailed;
    final showNetwork = networkUrl != null && networkUrl.isNotEmpty;

    if (showLocal) {
      imageContent = Image.file(
        File(localPath),
        fit: BoxFit.cover,
        width: display?.width,
        height: display?.height,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) {
          _localFailed = true;
          _logFailure(
            'pm_media_local_fallback_used',
            hasLocal: true,
          );
          // 回退到网络；若当前帧已无展示尺寸，交由下一步。
          return _buildNetwork(colors, display);
        },
      );
    } else if (showNetwork) {
      imageContent = _buildNetwork(colors, display);
    }

    // 有展示尺寸：独立气泡，图片自带圆角。
    if (display != null) {
      return SizedBox(
        width: display.width,
        height: display.height,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: imageContent ?? _buildSizedPlaceholder(colors, display),
        ),
      );
    }

    // 尚无展示尺寸（网络图且服务端未给宽高）：用 contain 等比展示，不裁切。
    if (imageContent != null) {
      return SizedBox(
        width: widget.maxWidth,
        height: widget.maxHeight.clamp(120, 260),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: imageContent,
        ),
      );
    }

    // 无任何可用来源：中性失败卡。
    return _buildFailureCard(colors, compact: true);
  }

  Widget _buildNetwork(ColorScheme colors, Size? display) {
    final url = widget.networkUrl;
    if (url == null || url.isEmpty) {
      return _buildFailureCard(colors, compact: display == null);
    }
    final fullUrl = ApiConstants.fullUrl(url);
    final resolvedCacheKey = widget.cacheKey ??
        PrivateMessageMediaCache.cacheKeyFor(
          fullUrl,
          accountId: widget.accountId,
        );
    return CachedNetworkImage(
      imageUrl: fullUrl,
      cacheKey: resolvedCacheKey,
      httpHeaders: widget.httpHeaders,
      cacheManager:
          widget.cacheManager ?? PrivateMessageMediaCache.instance.manager,
      fit: display == null ? BoxFit.contain : BoxFit.cover,
      width: display?.width,
      height: display?.height,
      fadeInDuration: Duration.zero,
      fadeOutDuration: Duration.zero,
      placeholder: (_, __) => _buildSizedPlaceholder(colors, display),
      errorWidget: (_, __, ___) {
        _logFailure('pm_media_load_failed');
        return _buildFailureCard(colors, compact: display == null);
      },
    );
  }

  Widget _buildSizedPlaceholder(ColorScheme colors, Size? display) {
    return ColoredBox(
      color: colors.surfaceContainerHighest.withValues(alpha: 0.4),
      child: const Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
    );
  }

  /// 中性失败卡：可重试，点击后重新加载。
  Widget _buildFailureCard(ColorScheme colors, {required bool compact}) {
    return Material(
      color: colors.surfaceContainer,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: _retry,
        child: Container(
          width: compact ? 140 : null,
          height: compact ? 100 : null,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            border: Border.all(color: colors.outlineVariant),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.broken_image_outlined,
                color: colors.onSurfaceVariant,
                size: 22,
              ),
              const SizedBox(height: 6),
              Text(
                '图片加载失败',
                style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
              ),
              const SizedBox(height: 2),
              Text(
                '点击重新加载',
                style: TextStyle(
                  color: colors.onSurfaceVariant.withValues(alpha: 0.7),
                  fontSize: 10,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
