import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';

import '../utils/image_decode_size.dart';
import '../utils/image_prefetch_coordinator.dart';
import '../utils/post_image_cache.dart';

/// 小于此大小的原图下载成本很低，进入查看器时直接使用原图。
///
/// 使用二进制 KB（1024 字节）与应用其他文件大小展示保持一致；边界值本身
/// 不自动加载，只有严格小于 600KB 才命中策略。
const int imageOriginalAutoLoadThresholdBytes = 600 * 1024;

/// 判断图片是否应该在进入全屏查看器时直接使用原图。
@visibleForTesting
bool shouldAutoLoadOriginalByDefault({
  required int originalSizeBytes,
  bool isAnimatedGif = false,
}) {
  // GIF 也遵守同一阈值：小 GIF 直出，大 GIF 留在静态预览并等待用户主动
  // 加载完整动画，避免进入查看器就占用大带宽和动画解码资源。
  return originalSizeBytes > 0 &&
      originalSizeBytes < imageOriginalAutoLoadThresholdBytes;
}

/// 将原图字节数格式化为查看器按钮文案。
@visibleForTesting
String formatImageFileSize(int bytes) {
  if (bytes <= 0) return '';
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
}

String? _optionalString(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

/// 全屏图片查看单项数据模型。
class ImageViewerItem {
  /// 旧调用方使用的显示地址。新图片链路请使用分层 URL 字段。
  final String? url;

  /// 预览占位档（通常为 thumb 480）。
  final String? thumbUrl;

  /// 全屏默认显示档（通常为 medium 1280）。
  final String? previewUrl;

  /// 可选的全屏预览档（通常为 viewer 2048），只在 previewUrl 不可用时使用。
  final String? viewerUrl;

  /// 用户主动查看/保存时使用的原图地址。
  final String? originalUrl;

  final String? localPath;
  final Uint8List? bytes;

  /// 旧接口的保存地址别名，保留以兼容私信等调用方。
  @Deprecated('Use originalUrl instead.')
  final String? downloadUrl;

  /// 服务端返回的原图大小。未知时为 0。
  final int originalSizeBytes;

  /// 服务端原图尺寸，供上层后续扩展使用；查看器本身不按它拉取原图。
  final int width;
  final int height;

  /// 服务端原图 MIME 类型。
  final String mimeType;

  /// 是否启用分层资源语义。启用后没有 ready 变体时绝不自动回退原图。
  final bool useProgressiveLoading;

  const ImageViewerItem({
    this.url,
    this.thumbUrl,
    this.previewUrl,
    this.viewerUrl,
    this.originalUrl,
    this.localPath,
    this.bytes,
    this.downloadUrl,
    this.originalSizeBytes = 0,
    this.width = 0,
    this.height = 0,
    this.mimeType = '',
    this.useProgressiveLoading = false,
  });

  String? get resolvedOriginalUrl =>
      _optionalString(originalUrl) ??
      _optionalString(downloadUrl) ??
      _optionalString(url);

  bool get isAnimatedGif {
    if (mimeType.toLowerCase() == 'image/gif') return true;
    return <String?>[
      resolvedOriginalUrl,
      viewerUrl,
      previewUrl,
      thumbUrl,
      url,
    ].whereType<String>().any(_isGifUrl);
  }

  bool get shouldUseOriginalByDefault =>
      resolvedOriginalUrl != null &&
      shouldAutoLoadOriginalByDefault(
        originalSizeBytes: originalSizeBytes,
        isAnimatedGif: isAnimatedGif,
      );

  bool get isEmpty =>
      _optionalString(url) == null &&
      _optionalString(thumbUrl) == null &&
      _optionalString(previewUrl) == null &&
      _optionalString(viewerUrl) == null &&
      _optionalString(originalUrl) == null &&
      _optionalString(downloadUrl) == null &&
      _optionalString(localPath) == null &&
      (bytes == null || bytes!.isEmpty);

  bool get isNotEmpty => !isEmpty;
}

class ImageViewerScreen extends StatefulWidget {
  final List<String> imageUrls;
  final int initialIndex;
  final Map<String, String> httpHeaders;

  /// 与 imageUrls 一一对应的本地内存字节（如刚上传的图片预览）；
  /// 对应下标为 null 时回退到网络/CachedNetworkImage。
  final List<Uint8List?>? imageBytes;

  /// 与 imageUrls 一一对应的本地文件路径；对应下标非 null 时优先读取本地
  /// 文件，让发送方与全屏查看共享同一 fallback 策略（本地 → 鉴权网络）。
  final List<String?>? localPaths;

  /// 与 imageUrls 一一对应的保存/下载原图地址；为空时保存回退到 imageUrls。
  final List<String?>? downloadUrls;

  /// 统一结构化列表（优先于 imageUrls/localPaths/imageBytes 解析）。
  final List<ImageViewerItem>? items;

  /// 自定义缓存管理器（如私信图片使用 [PrivateMessageMediaCache.instance.manager]）；
  /// 为空时回退到公开图片缓存 [PostImageCache.manager]。
  final BaseCacheManager? cacheManager;

  /// 针对私有图片等需要自定义账号隔离 cacheKey 的构建器；为空时使用 url 作为 cacheKey。
  final String Function(String url)? cacheKeyBuilder;

  /// 下载原图的 Dio 客户端。生产环境使用内置客户端，测试可注入适配器。
  @visibleForTesting
  final Dio? downloadClient;

  const ImageViewerScreen({
    super.key,
    this.imageUrls = const <String>[],
    this.initialIndex = 0,
    this.httpHeaders = const {},
    this.imageBytes,
    this.localPaths,
    this.downloadUrls,
    this.items,
    this.cacheManager,
    this.cacheKeyBuilder,
    this.downloadClient,
  });

  @override
  State<ImageViewerScreen> createState() => _ImageViewerScreenState();
}

/// 原图下载状态。预览图片始终独立于此状态渲染。
enum OriginalLoadState { idle, loading, ready, error }

class _ImageFileResult {
  final File file;
  final String sourceLabel;
  final String extension;
  final String mimeType;

  const _ImageFileResult(
    this.file,
    this.sourceLabel,
    this.extension,
    this.mimeType,
  );
}

String _guessExtensionFromBytes(List<int> bytes, String fallbackExt) {
  if (bytes.length >= 4) {
    if (bytes[0] == 0xFF && bytes[1] == 0xD8) return 'jpg';
    if (bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return 'png';
    }
    if (bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46) {
      return 'gif';
    }
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46) {
      return 'webp';
    }
  }
  return fallbackExt;
}

String _guessMimeType(String ext) {
  switch (ext.toLowerCase()) {
    case 'jpg':
    case 'jpeg':
      return 'image/jpeg';
    case 'png':
      return 'image/png';
    case 'gif':
      return 'image/gif';
    case 'webp':
      return 'image/webp';
    default:
      return 'image/png';
  }
}

String _extensionForImage({
  required String url,
  required String mimeType,
  String? contentType,
}) {
  final declaredMime = (contentType ?? mimeType).toLowerCase();
  if (declaredMime.contains('jpeg') || declaredMime.contains('jpg')) {
    return 'jpg';
  }
  if (declaredMime.contains('png')) return 'png';
  if (declaredMime.contains('gif')) return 'gif';
  if (declaredMime.contains('webp')) return 'webp';

  final path = Uri.tryParse(url)?.path ?? url;
  final dotIndex = path.lastIndexOf('.');
  if (dotIndex >= 0 && dotIndex + 1 < path.length) {
    final ext = path.substring(dotIndex + 1).toLowerCase();
    if (const {'jpg', 'jpeg', 'png', 'gif', 'webp'}.contains(ext)) {
      return ext == 'jpeg' ? 'jpg' : ext;
    }
  }
  return 'jpg';
}

bool _isGifUrl(String url) =>
    url.toLowerCase().split('?').first.endsWith('.gif');

class _ImageViewerScreenState extends State<ImageViewerScreen> {
  static const int _maxOriginalFileEntries = 3;

  late PageController _pageController;
  late int _currentIndex;
  late final List<ImageViewerItem> _resolvedItems;
  late final ImagePrefetchCoordinator _prefetchCoordinator;
  late final Dio _downloadClientInstance;
  late final bool _ownsDownloadClient;
  int _prefetchDirection = 1;

  bool _isSaving = false;
  final Map<int, _ImageFileResult> _originalFiles = {};
  final Map<int, OriginalLoadState> _originalStates = {};
  final Map<int, double> _originalProgress = {};
  final Map<int, Object> _originalErrors = {};
  final Map<int, Future<_ImageFileResult>> _originalLoads = {};
  final Map<int, CancelToken> _originalCancelTokens = {};
  final Map<int, DateTime> _lastOriginalProgressUpdates = {};
  final Set<String> _ownedTemporaryFiles = <String>{};

  @override
  void initState() {
    super.initState();
    _resolvedItems = _computeResolvedItems();
    final total = _resolvedItems.length;
    _currentIndex = total == 0 ? 0 : widget.initialIndex.clamp(0, total - 1);
    _pageController = PageController(initialPage: _currentIndex);
    _prefetchCoordinator = ImagePrefetchCoordinator();
    _downloadClientInstance = widget.downloadClient ??
        Dio(
          BaseOptions(
            connectTimeout: const Duration(seconds: 10),
            sendTimeout: const Duration(seconds: 10),
            receiveTimeout: const Duration(seconds: 60),
          ),
        );
    _ownsDownloadClient = widget.downloadClient == null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _prefetchAdjacentImages();
    });
  }

  List<ImageViewerItem> _computeResolvedItems() {
    if (widget.items != null && widget.items!.isNotEmpty) {
      return List<ImageViewerItem>.unmodifiable(widget.items!);
    }

    final urlsLen = widget.imageUrls.length;
    final bytesLen = widget.imageBytes?.length ?? 0;
    final pathsLen = widget.localPaths?.length ?? 0;
    final downloadLen = widget.downloadUrls?.length ?? 0;
    var maxLen = urlsLen;
    if (bytesLen > maxLen) maxLen = bytesLen;
    if (pathsLen > maxLen) maxLen = pathsLen;
    if (downloadLen > maxLen) maxLen = downloadLen;
    if (maxLen == 0) return const <ImageViewerItem>[];

    return List<ImageViewerItem>.generate(maxLen, (index) {
      final url =
          index < urlsLen ? _optionalString(widget.imageUrls[index]) : null;
      final bytes = widget.imageBytes != null && index < bytesLen
          ? widget.imageBytes![index]
          : null;
      final localPath = widget.localPaths != null && index < pathsLen
          ? _optionalString(widget.localPaths![index])
          : null;
      final downloadUrl = widget.downloadUrls != null && index < downloadLen
          ? _optionalString(widget.downloadUrls![index])
          : null;
      return ImageViewerItem(
        url: url,
        localPath: localPath,
        bytes: bytes != null && bytes.isNotEmpty ? bytes : null,
        originalUrl: downloadUrl,
        downloadUrl: downloadUrl,
      );
    });
  }

  @override
  void dispose() {
    _prefetchCoordinator.invalidate();
    for (final token in _originalCancelTokens.values) {
      if (!token.isCancelled) token.cancel('查看器已关闭');
    }
    for (final path in _ownedTemporaryFiles) {
      unawaited(_deleteFileIfExists(File(path)));
    }
    if (_ownsDownloadClient) _downloadClientInstance.close(force: true);
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final total = _resolvedItems.length;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Text(
          total == 0 ? '0 / 0' : '${_currentIndex + 1} / $total',
          style: const TextStyle(color: Colors.white),
        ),
        actions: [
          IconButton(
            tooltip: _isSaving ? '正在保存原图' : '保存原图',
            icon: _isSaving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      color: Colors.white,
                      strokeWidth: 2,
                    ),
                  )
                : const Icon(Icons.download),
            onPressed: total == 0 ? null : _saveImage,
          ),
        ],
      ),
      body: total == 0
          ? const Center(
              child: Text(
                '暂无图片',
                style: TextStyle(color: Colors.white70),
              ),
            )
          : Stack(
              fit: StackFit.expand,
              children: [
                PageView.builder(
                  controller: _pageController,
                  itemCount: total,
                  onPageChanged: (index) {
                    if (!mounted) return;
                    final direction = index.compareTo(_currentIndex);
                    if (direction != 0) _prefetchDirection = direction;
                    _cancelOriginalLoadsExcept(index);
                    setState(() => _currentIndex = index);
                    _prefetchCoordinator.invalidate();
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) _prefetchAdjacentImages();
                    });
                  },
                  itemBuilder: (context, index) {
                    return GestureDetector(
                      onLongPress: () => _showLongPressMenu(context),
                      child: InteractiveViewer(
                        child: Center(
                          child: _buildPageImage(index),
                        ),
                      ),
                    );
                  },
                ),
                Positioned(
                  left: 16,
                  bottom: 16,
                  child: SafeArea(
                    top: false,
                    left: false,
                    right: false,
                    child: _buildOriginalAction(_currentIndex),
                  ),
                ),
              ],
            ),
    );
  }

  void _showLongPressMenu(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.all(16),
        child: Material(
          color: Theme.of(context).brightness == Brightness.dark
              ? const Color(0xFF1E1E1E)
              : Colors.white,
          borderRadius: BorderRadius.circular(16),
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.download),
                title: const Text('保存原图'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _saveImage();
                },
              ),
              ListTile(
                leading: const Icon(Icons.close),
                title: const Text('取消'),
                onTap: () => Navigator.pop(sheetContext),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPageImage(int index) {
    if (index < 0 || index >= _resolvedItems.length) {
      return const Icon(Icons.error, color: Colors.white, size: 48);
    }
    final item = _resolvedItems[index];

    if (item.bytes != null && item.bytes!.isNotEmpty) {
      return Image(
        key: ValueKey('viewer-memory-image-$index'),
        image: _decodeConstrained(MemoryImage(item.bytes!)),
        fit: BoxFit.contain,
      );
    }

    final localPath = _optionalString(item.localPath);
    if (localPath != null) {
      return Image(
        key: ValueKey('viewer-local-image-$index'),
        image: _decodeConstrained(FileImage(File(localPath))),
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => _buildPreviewImage(item, index),
      );
    }

    final originalFile = _originalFiles[index];
    if (originalFile != null) {
      return Image(
        key: ValueKey('viewer-original-file-$index'),
        image: _imageProviderForFile(originalFile.file, item),
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => _buildPreviewImage(item, index),
      );
    }

    if (_shouldAutoLoadOriginalLayer(item)) {
      return _buildAutoOriginalImage(item, index);
    }

    return _buildPreviewImage(item, index);
  }

  Widget _buildAutoOriginalImage(ImageViewerItem item, int index) {
    final originalUrl = item.resolvedOriginalUrl;
    if (originalUrl == null) return _buildPreviewImage(item, index);

    final hasPreview = _hasPreview(item);
    return Stack(
      fit: StackFit.expand,
      children: [
        if (hasPreview) _buildPreviewImage(item, index),
        _buildNetworkImage(
          originalUrl,
          index: index,
          key: ValueKey('viewer-original-image-$index'),
          isAnimated: item.isAnimatedGif,
          showLoadingIndicator: !hasPreview,
          fallbackUrls: _previewCandidates(item),
        ),
      ],
    );
  }

  Widget _buildPreviewImage(ImageViewerItem item, int index) {
    final candidates = _previewCandidates(item);
    if (candidates.isEmpty) {
      return const Center(
        child: Icon(
          Icons.image_not_supported_outlined,
          color: Colors.white54,
          size: 40,
        ),
      );
    }

    final primary = candidates.first;
    final fallbackUrls = candidates.skip(1).toList(growable: false);
    final thumb = _optionalString(item.thumbUrl);
    final showThumbUnderlay = thumb != null && thumb != primary;
    final primaryWidget = _buildNetworkImage(
      primary,
      index: index,
      isAnimated: item.isAnimatedGif && _isGifUrl(primary),
      showLoadingIndicator: !showThumbUnderlay,
      fallbackUrls: [
        ...fallbackUrls,
        if (showThumbUnderlay) thumb,
      ],
    );

    if (!showThumbUnderlay) return primaryWidget;
    return Stack(
      fit: StackFit.expand,
      children: [
        _buildNetworkImage(
          thumb,
          index: index,
          isAnimated: item.isAnimatedGif && _isGifUrl(thumb),
          showLoadingIndicator: false,
        ),
        primaryWidget,
      ],
    );
  }

  List<String> _previewCandidates(ImageViewerItem item) {
    final candidates = <String>[];
    void add(String? raw) {
      final value = _optionalString(raw);
      if (value == null || candidates.contains(value)) return;
      candidates.add(value);
    }

    if (item.useProgressiveLoading) {
      // 结构化帖子图片只允许使用已由入口筛选过的 ready 变体；原图不在候选内。
      add(item.previewUrl);
      add(item.viewerUrl);
      add(item.url);
      add(item.thumbUrl);
      return candidates;
    }

    // 兼容旧的 imageUrls/downloadUrls 调用：url 仍是默认显示档。
    add(item.url);
    add(item.previewUrl);
    add(item.viewerUrl);
    if (candidates.isEmpty) add(item.originalUrl);
    if (candidates.isEmpty) add(item.downloadUrl);
    return candidates;
  }

  bool _hasPreview(ImageViewerItem item) => _previewCandidates(item).isNotEmpty;

  ImageProvider _decodeConstrained(ImageProvider provider) {
    return ResizeImage(
      provider,
      width: imageViewerLongEdge,
      height: imageViewerLongEdge,
      policy: ResizeImagePolicy.fit,
    );
  }

  ImageProvider _imageProviderForFile(File file, ImageViewerItem item) {
    final provider = FileImage(file);
    return item.isAnimatedGif ? provider : _decodeConstrained(provider);
  }

  ImageProvider _imageProviderForUrl(
    String url, {
    bool isAnimated = false,
  }) {
    final provider = CachedNetworkImageProvider(
      url,
      headers: widget.httpHeaders,
      cacheManager: _cacheManager,
      cacheKey: _providerCacheKey(url),
    );
    return isAnimated || _isGifUrl(url)
        ? provider
        : _decodeConstrained(provider);
  }

  Widget _buildNetworkImage(
    String url, {
    required int index,
    Key? key,
    bool isAnimated = false,
    bool showLoadingIndicator = true,
    List<String> fallbackUrls = const <String>[],
  }) {
    final nextFallback = fallbackUrls.isEmpty
        ? const <String>[]
        : fallbackUrls.skip(1).toList(growable: false);
    final errorWidget = fallbackUrls.isEmpty
        ? const Icon(Icons.error, color: Colors.white, size: 48)
        : _buildNetworkImage(
            fallbackUrls.first,
            index: index,
            isAnimated: isAnimated && _isGifUrl(fallbackUrls.first),
            showLoadingIndicator: false,
            fallbackUrls: nextFallback,
          );

    return Image(
      key: key,
      image: _imageProviderForUrl(url, isAnimated: isAnimated),
      fit: BoxFit.contain,
      loadingBuilder: (context, child, loadingProgress) {
        if (loadingProgress == null) return child;
        if (!showLoadingIndicator) return const SizedBox.expand();
        return const Center(
          child: CircularProgressIndicator(color: Colors.white),
        );
      },
      errorBuilder: (_, __, ___) => errorWidget,
    );
  }

  Widget _buildOriginalAction(int index) {
    if (index < 0 || index >= _resolvedItems.length) {
      return const SizedBox.shrink();
    }
    final item = _resolvedItems[index];
    if (!_canOfferOriginal(item)) return const SizedBox.shrink();

    final state = _originalStates[index] ?? OriginalLoadState.idle;
    if (state == OriginalLoadState.ready) return const SizedBox.shrink();

    final sizeLabel = formatImageFileSize(item.originalSizeBytes);
    final sizeSuffix = sizeLabel.isEmpty ? '' : ' $sizeLabel';
    final isLoading = state == OriginalLoadState.loading;
    final percent = ((_originalProgress[index] ?? 0) * 100).round();
    final title = isLoading
        ? (percent > 0 ? '$percent%' : '加载中…')
        : state == OriginalLoadState.error
            ? '重试原图$sizeSuffix'
            : '查看原图$sizeSuffix';
    final semanticLabel = isLoading
        ? '正在加载原图，$title，点击取消'
        : state == OriginalLoadState.error
            ? '原图加载失败，点击重试$sizeSuffix'
            : '查看原图$sizeSuffix';

    return Semantics(
      button: true,
      label: semanticLabel,
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: isLoading
              ? () => _cancelOriginalLoad(index)
              : () => _requestOriginal(index),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (isLoading)
                    const Padding(
                      padding: EdgeInsets.only(right: 8),
                      child: Icon(Icons.close, size: 18, color: Colors.black87),
                    ),
                  Text(
                    title,
                    style: const TextStyle(
                      color: Colors.black87,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  bool _canOfferOriginal(ImageViewerItem item) {
    final originalUrl = item.resolvedOriginalUrl;
    if (originalUrl == null || _shouldAutoLoadOriginalLayer(item)) return false;
    if (item.useProgressiveLoading) return true;

    final displayUrl = _optionalString(item.url);
    final explicitOriginal = _optionalString(item.originalUrl);
    final legacyDownload = _optionalString(item.downloadUrl);
    return (explicitOriginal != null && explicitOriginal != displayUrl) ||
        (legacyDownload != null && legacyDownload != displayUrl);
  }

  bool _shouldAutoLoadOriginalLayer(ImageViewerItem item) {
    if (!item.shouldUseOriginalByDefault) return false;
    // 旧 imageUrls 调用没有大小/分层元数据；GIF 在该路径本来就只有一个
    // 原图显示，避免为了兼容性额外叠一层相同的 Image widget。
    return item.useProgressiveLoading ||
        item.originalSizeBytes > 0 ||
        item.originalUrl != null ||
        item.downloadUrl != null;
  }

  void _requestOriginal(int index) {
    if (index < 0 || index >= _resolvedItems.length) return;
    final state = _originalStates[index] ?? OriginalLoadState.idle;
    if (state == OriginalLoadState.loading ||
        state == OriginalLoadState.ready) {
      return;
    }
    // 原图属于高成本动作，同一查看器同时只保留一个下载；切换图片或
    // 用户点击另一张时，前一个请求会收到 Dio cancel，而不是继续抢带宽。
    _cancelOriginalLoadsExcept(index);
    final future = _loadOriginalFile(index);
    unawaited(future.then<void>((_) {}, onError: (_, __) {}));
  }

  void _cancelOriginalLoad(int index) {
    final token = _originalCancelTokens[index];
    if (token != null && !token.isCancelled) {
      token.cancel('用户取消原图下载');
    }
  }

  void _cancelOriginalLoadsExcept(int keepIndex) {
    for (final index in _originalCancelTokens.keys.toList(growable: false)) {
      if (index != keepIndex) _cancelOriginalLoad(index);
    }
  }

  Future<_ImageFileResult> _loadImageFileForSaving(int index) async {
    if (index < 0 || index >= _resolvedItems.length) {
      throw Exception('图片不存在');
    }
    final existing = _originalFiles[index];
    if (existing != null) return existing;

    final item = _resolvedItems[index];
    if (item.bytes != null && item.bytes!.isNotEmpty) {
      final ext = _guessExtensionFromBytes(item.bytes!, 'png');
      final file = await _writeBytesToTemporaryFile(
        item.bytes!,
        'sylulive_memory_$index.$ext',
      );
      final result = _ImageFileResult(
        file,
        '原图',
        ext,
        _guessMimeType(ext),
      );
      _rememberOriginalFile(index, result);
      return result;
    }

    final localPath = _optionalString(item.localPath);
    if (localPath != null) {
      final file = File(localPath);
      if (await file.exists() && await file.length() > 0) {
        final ext = _extensionForImage(
          url: localPath,
          mimeType: item.mimeType,
        );
        final result = _ImageFileResult(
          file,
          '原图',
          ext,
          _guessMimeType(ext),
        );
        _rememberOriginalFile(index, result);
        return result;
      }
    }

    final originalUrl = item.resolvedOriginalUrl;
    if (originalUrl == null) {
      throw Exception('原图不可用，且本地文件不存在');
    }
    return _loadOriginalFile(index);
  }

  Future<File> _writeBytesToTemporaryFile(
    Uint8List bytes,
    String filename,
  ) async {
    final tempDir = await getTemporaryDirectory();
    final file = File('${tempDir.path}/$filename');
    await file.writeAsBytes(bytes, flush: true);
    _ownedTemporaryFiles.add(file.path);
    return file;
  }

  Future<_ImageFileResult> _loadOriginalFile(int index) {
    if (index < 0 || index >= _resolvedItems.length) {
      return Future<_ImageFileResult>.error(Exception('图片不存在'));
    }
    final existing = _originalFiles[index];
    if (existing != null) return Future<_ImageFileResult>.value(existing);
    final inFlight = _originalLoads[index];
    if (inFlight != null) return inFlight;

    if (mounted) {
      setState(() {
        _originalStates[index] = OriginalLoadState.loading;
        _originalProgress[index] = 0;
        _originalErrors.remove(index);
      });
    }

    late final Future<_ImageFileResult> future;
    future = _loadOriginalFileInternal(index);
    _originalLoads[index] = future;
    future.then<void>(
      (result) {
        if (identical(_originalLoads[index], future)) {
          _originalLoads.remove(index);
        }
        _rememberOriginalFile(index, result);
        _lastOriginalProgressUpdates.remove(index);
        if (!mounted) return;
        setState(() {
          _originalStates[index] = OriginalLoadState.ready;
          _originalProgress[index] = 1;
        });
      },
      onError: (Object error, StackTrace stackTrace) {
        if (identical(_originalLoads[index], future)) {
          _originalLoads.remove(index);
        }
        final isCancelled =
            error is DioException && CancelToken.isCancel(error);
        if (!mounted) return;
        setState(() {
          _originalStates[index] =
              isCancelled ? OriginalLoadState.idle : OriginalLoadState.error;
          if (isCancelled) {
            _originalProgress.remove(index);
            _lastOriginalProgressUpdates.remove(index);
          } else {
            _originalErrors[index] = error;
          }
        });
      },
    );
    return future;
  }

  Future<_ImageFileResult> _loadOriginalFileInternal(int index) async {
    final item = _resolvedItems[index];
    final originalUrl = item.resolvedOriginalUrl;
    if (originalUrl == null) {
      throw Exception('原图地址为空');
    }

    final cancelToken = CancelToken();
    _originalCancelTokens[index] = cancelToken;
    File? temporaryFile;
    File? completedFile;
    try {
      // 先查与显示一致的磁盘缓存，命中时不发送 origin 请求。
      final cachedFile = await _readCachedFile(originalUrl);
      if (cachedFile != null) {
        final ext = _extensionForImage(
          url: originalUrl,
          mimeType: item.mimeType,
        );
        return _ImageFileResult(
          cachedFile,
          '缓存原图',
          ext,
          _guessMimeType(ext),
        );
      }

      final tempDir = await getTemporaryDirectory();
      final ext = _extensionForImage(
        url: originalUrl,
        mimeType: item.mimeType,
      );
      final basename =
          'sylulive_original_${DateTime.now().microsecondsSinceEpoch}_$index';
      temporaryFile = File(
        '${tempDir.path}/$basename.$ext.part',
      );

      final response = await _downloadClient().download(
        originalUrl,
        temporaryFile.path,
        cancelToken: cancelToken,
        deleteOnError: true,
        onReceiveProgress: (received, total) {
          _scheduleOriginalProgress(index, received, total);
        },
        options: Options(headers: widget.httpHeaders),
      );

      // Dio 返回时文件句柄已经关闭；这里的校验和同目录改名只涉及文件元数据，
      // 使用同步操作可以避免 UI 测试/低端设备上异步文件事件被延迟时留下半成品。
      if (!temporaryFile.existsSync() || temporaryFile.lengthSync() <= 0) {
        throw Exception('原图下载结果为空');
      }

      final responseExt = _extensionForImage(
        url: originalUrl,
        mimeType: item.mimeType,
        contentType: response.headers.value('content-type'),
      );
      // 下载未完成时只存在 .part；成功后先在同一目录原子改名，再交给缓存。
      // 缓存写入失败时也返回这个正式文件，避免把半成品路径当成原图。
      final downloadedFile = File('${tempDir.path}/$basename.$responseExt');
      completedFile = downloadedFile;
      temporaryFile.renameSync(downloadedFile.path);
      temporaryFile = null;
      final cached = await _putDownloadedFileInCache(
        originalUrl,
        downloadedFile,
        responseExt,
      );
      final file = cached ?? downloadedFile;
      if (cached == null) {
        _ownedTemporaryFiles.add(file.path);
      } else {
        if (cached.path != downloadedFile.path) {
          await _deleteFileIfExists(downloadedFile);
        }
        completedFile = null;
      }

      return _ImageFileResult(
        file,
        '原图',
        responseExt,
        _guessMimeType(responseExt),
      );
    } catch (_) {
      if (temporaryFile != null) {
        await _deleteFileIfExists(temporaryFile);
        _ownedTemporaryFiles.remove(temporaryFile.path);
      }
      if (completedFile != null) {
        await _deleteFileIfExists(completedFile);
        _ownedTemporaryFiles.remove(completedFile.path);
      }
      rethrow;
    } finally {
      if (identical(_originalCancelTokens[index], cancelToken)) {
        _originalCancelTokens.remove(index);
      }
    }
  }

  void _updateOriginalProgress(int index, int received, int total) {
    if (!mounted || index < 0 || index >= _resolvedItems.length) return;
    final fallbackTotal = _resolvedItems[index].originalSizeBytes;
    final expectedTotal = total > 0 ? total : fallbackTotal;
    if (expectedTotal <= 0) return;
    final next = (received / expectedTotal).clamp(0.0, 1.0).toDouble();
    final previous = _originalProgress[index];
    if (previous != null && (next - previous).abs() < 0.01 && next < 1) {
      return;
    }
    final now = DateTime.now();
    final lastUpdate = _lastOriginalProgressUpdates[index];
    if (next < 1 &&
        lastUpdate != null &&
        now.difference(lastUpdate) < const Duration(milliseconds: 100)) {
      return;
    }
    _lastOriginalProgressUpdates[index] = now;
    setState(() => _originalProgress[index] = next);
  }

  void _scheduleOriginalProgress(int index, int received, int total) {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _updateOriginalProgress(index, received, total);
    });
  }

  Dio _downloadClient() {
    return _downloadClientInstance;
  }

  BaseCacheManager get _cacheManager =>
      widget.cacheManager ?? PostImageCache.manager;

  String _cacheKeyFor(String url) {
    final custom = widget.cacheKeyBuilder?.call(url);
    return custom == null || custom.isEmpty ? url : custom;
  }

  String? _providerCacheKey(String url) {
    return widget.cacheKeyBuilder == null ? null : _cacheKeyFor(url);
  }

  Future<File?> _readCachedFile(String url) async {
    final managers = widget.cacheManager != null
        ? <BaseCacheManager>[widget.cacheManager!]
        : <BaseCacheManager>[
            PostImageCache.manager,
            DefaultCacheManager(),
          ];
    final key = _cacheKeyFor(url);

    for (final manager in managers) {
      try {
        final info = await manager.getFileFromCache(key);
        final path = info?.file.path;
        if (path == null || path.isEmpty) continue;
        final file = File(path);
        if (await file.exists() && await file.length() > 0) return file;
      } catch (_) {
        // 某个缓存目录不可读时继续尝试下一个公开缓存；私有缓存不会旁路。
      }
    }
    return null;
  }

  Future<File?> _putDownloadedFileInCache(
    String url,
    File downloaded,
    String extension,
  ) async {
    try {
      final cached = await _cacheManager.putFileStream(
        url,
        downloaded.openRead(),
        key: _cacheKeyFor(url),
        maxAge: PostImageCache.stalePeriod,
        fileExtension: extension,
      );
      final file = File(cached.path);
      if (await file.exists() && await file.length() > 0) return file;
    } catch (_) {
      // 缓存失败不影响本次查看，保留临时文件作为当前会话的原图。
    }
    return null;
  }

  Future<void> _saveImage() async {
    if (_isSaving || _resolvedItems.isEmpty) return;
    if (mounted) setState(() => _isSaving = true);

    try {
      final hasAccess = await Gal.hasAccess();
      if (!hasAccess) {
        final request = await Gal.requestAccess();
        if (!request) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('需要相册权限才能保存图片')),
          );
          return;
        }
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('正在准备原图...')),
      );

      final image = await _loadImageFileForSaving(_currentIndex);
      await Gal.putImage(image.file.path, album: '沈理');

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${image.sourceLabel}已保存到"沈理"相册')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存失败: $error')),
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  void _rememberOriginalFile(int index, _ImageFileResult result) {
    _originalFiles[index] = result;
    while (_originalFiles.length > _maxOriginalFileEntries) {
      final oldestIndex = _originalFiles.keys.first;
      final removed = _originalFiles.remove(oldestIndex);
      if (removed == null) continue;
      final path = removed.file.path;
      if (_ownedTemporaryFiles.remove(path)) {
        unawaited(_deleteFileIfExists(removed.file));
      }
    }
  }

  Future<void> _deleteFileIfExists(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // 临时文件清理失败不能影响查看器退出或主流程。
    }
  }

  void _prefetchAdjacentImages() {
    final tasks = adjacentImageIndexes(
      currentIndex: _currentIndex,
      itemCount: _resolvedItems.length,
      priorityDirection: _prefetchDirection,
    ).map((index) {
      final item = _resolvedItems[index];
      final url = _prefetchUrl(item);
      if (url == null || _isGifUrl(url)) return null;

      final cacheKey = _cacheKeyFor(url);
      return ImagePrefetchTask(
        cacheKey: cacheKey,
        isCached: () async =>
            await _cacheManager.getFileFromCache(cacheKey) != null,
        preload: () {
          if (!mounted) return Future<void>.value();
          return precacheImage(
            _imageProviderForUrl(url),
            context,
          );
        },
      );
    }).whereType<ImagePrefetchTask>();

    // 只串行预取一张相邻预览，避免与当前页竞争带宽；结构化图片永不预取原图。
    unawaited(_prefetchCoordinator.enqueue(tasks, limit: 1));
  }

  String? _prefetchUrl(ImageViewerItem item) {
    final original = item.resolvedOriginalUrl;
    if (item.useProgressiveLoading) {
      for (final candidate in <String?>[
        item.previewUrl,
        item.viewerUrl,
        item.thumbUrl,
      ]) {
        final url = _optionalString(candidate);
        if (url != null && url != original) return url;
      }
      return null;
    }

    final legacy = _optionalString(item.url);
    if (legacy == null) return null;
    if (item.originalUrl != null && legacy == original) return null;
    return legacy;
  }
}
