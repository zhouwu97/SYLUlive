import 'dart:io';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../config/api_constants.dart';
import '../services/diagnostic_log_service.dart';
import '../utils/image_header_size_parser.dart';
import '../utils/image_decode_size.dart';
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

  /// 图片点击（打开大图等）。仅在展示尺寸解析完成后才可触发：
  /// 服务端给定宽高、或本地/网络 intrinsic 尺寸解析成功，且 [onTap] 非空时，
  /// 可点击区域严格等于渲染出的图片框，避免"点图片旁边空白也打开"。
  final VoidCallback? onTap;

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
    this.onTap,
  });

  @override
  State<PrivateMessageImage> createState() => _PrivateMessageImageState();
}

class _PrivateMessageImageState extends State<PrivateMessageImage> {
  Size? _intrinsic;
  bool _localFailed = false;
  int _loadAttempt = 0;
  ImageStream? _networkStream;
  ImageStreamListener? _networkStreamListener;

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

  @override
  void dispose() {
    _networkStream?.removeListener(_networkStreamListener!);
    super.dispose();
  }

  bool get _hasServerSize => widget.serverWidth > 0 && widget.serverHeight > 0;

  /// 服务端没给宽高时，从本地文件头或网络图片解码解析出真实 intrinsic 尺寸。
  void _resolveIntrinsic() {
    if (_hasServerSize) return;
    final localPath = widget.localPath;
    if (localPath != null && localPath.isNotEmpty) {
      _resolveLocalIntrinsic();
    } else {
      _resolveNetworkIntrinsic();
    }
  }

  /// 本地文件：使用轻量级文件头解析器提取尺寸，不将整图读入内存。
  Future<void> _resolveLocalIntrinsic() async {
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

  /// 网络图片：通过 ImageProvider.resolve() 解码拿到真实宽高，
  /// 避免服务端缺宽高时误用固定 260×260 透明布局框。
  void _resolveNetworkIntrinsic() {
    _networkStream?.removeListener(_networkStreamListener!);
    _networkStream = null;
    final url = widget.networkUrl;
    if (url == null || url.isEmpty) return;
    final fullUrl = ApiConstants.fullUrl(url);
    final key = widget.cacheKey ??
        PrivateMessageMediaCache.cacheKeyFor(
          fullUrl,
          accountId: widget.accountId,
        );
    final provider = CachedNetworkImageProvider(
      fullUrl,
      headers: widget.httpHeaders,
      cacheManager:
          widget.cacheManager ?? PrivateMessageMediaCache.instance.manager,
      cacheKey: key,
    );
    // intrinsic 解析也限制解码尺寸，避免为了获取宽高把原图完整解码一次，
    // 随后 CachedNetworkImage 又重复解码同一张大图。
    final target = calculateImageDecodeTarget(
      logicalSize: Size(widget.maxWidth, widget.maxHeight),
      // initState 不能依赖 MediaQuery；intrinsic 只需要保持比例，使用 1x
      // 的保守目标即可，实际展示阶段会按当前 DPR 再次限制解码。
      devicePixelRatio: 1.0,
      maxLongEdge: imageMediumLongEdge,
      fallbackLogicalSize: const Size(260, 320),
    );
    final resolvedProvider = ResizeImage(
      provider,
      width: target.width,
      height: target.height,
      policy: ResizeImagePolicy.fit,
    );
    final stream = resolvedProvider.resolve(const ImageConfiguration());
    late ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        final image = info.image;
        final width = image.width.toDouble();
        final height = image.height.toDouble();
        if (!mounted || _hasServerSize || _intrinsic != null) {
          stream.removeListener(listener);
          return;
        }
        if (width <= 0 || height <= 0) {
          stream.removeListener(listener);
          return;
        }
        setState(() => _intrinsic = ui.Size(width, height));
        stream.removeListener(listener);
      },
      onError: (error, stackTrace) {
        // 尺寸解析失败不阻塞：图片仍沿正常渲染路径展示（此时无精确点击区）。
        stream.removeListener(listener);
      },
    );
    _networkStream = stream;
    _networkStreamListener = listener;
    stream.addListener(listener);
  }

  Size? get _sourceSize {
    if (_hasServerSize) {
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
      final target = _decodeTarget(display);
      imageContent = Image.file(
        File(localPath),
        fit: BoxFit.cover,
        width: display?.width,
        height: display?.height,
        cacheWidth: target?.width,
        cacheHeight: target?.height,
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

    // 无任何可用来源：中性失败卡（失败卡自带"点击重试"，不受外层开大图约束）。
    if (imageContent == null) {
      return _buildFailureCard(colors, compact: true);
    }

    // 点击打开大图只绑定到渲染出的精确图片框：服务端给宽高、或本地/网络
    // intrinsic 解析成功（display != null）时才可触发，避免"点图片旁空白也打开"。
    final openViewerTap = display != null ? widget.onTap : null;

    Widget box;
    if (display != null) {
      // 已解析出精确展示尺寸：可点击区域 == 视觉图片尺寸。
      box = SizedBox(
        width: display.width,
        height: display.height,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: imageContent,
        ),
      );
    } else {
      // 网络图且尺寸尚未解析：用 contain 等比展示且不裁切，但不可点击打开大图。
      box = SizedBox(
        width: widget.maxWidth,
        height: widget.maxHeight.clamp(120, 260),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: imageContent,
        ),
      );
    }

    return GestureDetector(
      onTap: openViewerTap,
      child: box,
    );
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
    final target = _decodeTarget(display);
    return CachedNetworkImage(
      imageUrl: fullUrl,
      cacheKey: resolvedCacheKey,
      httpHeaders: widget.httpHeaders,
      cacheManager:
          widget.cacheManager ?? PrivateMessageMediaCache.instance.manager,
      fit: display == null ? BoxFit.contain : BoxFit.cover,
      width: display?.width,
      height: display?.height,
      memCacheWidth: target?.width,
      memCacheHeight: target?.height,
      fadeInDuration: Duration.zero,
      fadeOutDuration: Duration.zero,
      placeholder: (_, __) => _buildSizedPlaceholder(colors, display),
      errorWidget: (_, __, ___) {
        _logFailure('pm_media_load_failed');
        return _buildFailureCard(colors, compact: display == null);
      },
    );
  }

  ImageDecodeTarget? _decodeTarget(Size? display) {
    final logicalSize = display ?? Size(widget.maxWidth, widget.maxHeight);
    if (logicalSize.width <= 0 || logicalSize.height <= 0) return null;
    return calculateImageDecodeTarget(
      logicalSize: logicalSize,
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
      maxLongEdge: imageMediumLongEdge,
      fallbackLogicalSize: const Size(260, 320),
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
