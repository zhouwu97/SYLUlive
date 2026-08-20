import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';

import '../utils/post_image_cache.dart';

/// 全屏图片查看单项数据模型。
class ImageViewerItem {
  final String? url;
  final String? localPath;
  final Uint8List? bytes;

  const ImageViewerItem({
    this.url,
    this.localPath,
    this.bytes,
  });

  bool get isEmpty =>
      (url == null || url!.trim().isEmpty) &&
      (localPath == null || localPath!.trim().isEmpty) &&
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

  /// 统一结构化列表（优先于 imageUrls/localPaths/imageBytes 解析）。
  final List<ImageViewerItem>? items;

  /// 自定义缓存管理器（如私信图片使用 [PrivateMessageMediaCache.instance.manager]）；
  /// 为空时回退到公开图片缓存 [PostImageCache.manager]。
  final BaseCacheManager? cacheManager;

  /// 针对私有图片等需要自定义账号隔离 cacheKey 的构建器；为空时使用 url 作为 cacheKey。
  final String Function(String url)? cacheKeyBuilder;

  const ImageViewerScreen({
    super.key,
    this.imageUrls = const <String>[],
    this.initialIndex = 0,
    this.httpHeaders = const {},
    this.imageBytes,
    this.localPaths,
    this.items,
    this.cacheManager,
    this.cacheKeyBuilder,
  });

  @override
  State<ImageViewerScreen> createState() => _ImageViewerScreenState();
}

class _ImageBytesResult {
  final Uint8List bytes;
  final String sourceLabel;
  final String extension;
  final String mimeType;

  const _ImageBytesResult(
      this.bytes, this.sourceLabel, this.extension, this.mimeType);
}

String _guessExtensionFromBytes(List<int> bytes, String fallbackExt) {
  if (bytes.length >= 4) {
    if (bytes[0] == 0xFF && bytes[1] == 0xD8) {
      return 'jpg';
    }
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
  switch (ext) {
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

class _ImageViewerScreenState extends State<ImageViewerScreen> {
  static const int _maxDownloadedImageEntries = 3;
  static const int _maxGalleryDimension = 4096;

  late PageController _pageController;
  late int _currentIndex;
  late final List<ImageViewerItem> _resolvedItems;
  bool _isSaving = false;
  final Map<int, _ImageBytesResult> _downloadedImages = {};

  @override
  void initState() {
    super.initState();
    _resolvedItems = _computeResolvedItems();
    final total = _resolvedItems.length;
    _currentIndex = total == 0 ? 0 : widget.initialIndex.clamp(0, total - 1);
    _pageController = PageController(initialPage: _currentIndex);
  }

  List<ImageViewerItem> _computeResolvedItems() {
    if (widget.items != null && widget.items!.isNotEmpty) {
      return widget.items!;
    }
    final int urlsLen = widget.imageUrls.length;
    final int bytesLen = widget.imageBytes?.length ?? 0;
    final int pathsLen = widget.localPaths?.length ?? 0;
    int maxLen = urlsLen;
    if (bytesLen > maxLen) maxLen = bytesLen;
    if (pathsLen > maxLen) maxLen = pathsLen;
    if (maxLen == 0) return const [];

    return List<ImageViewerItem>.generate(maxLen, (i) {
      final String? url = i < urlsLen ? widget.imageUrls[i] : null;
      final Uint8List? bytes = (widget.imageBytes != null && i < bytesLen)
          ? widget.imageBytes![i]
          : null;
      final String? localPath = (widget.localPaths != null && i < pathsLen)
          ? widget.localPaths![i]
          : null;
      return ImageViewerItem(
        url: (url != null && url.isNotEmpty) ? url : null,
        localPath:
            (localPath != null && localPath.isNotEmpty) ? localPath : null,
        bytes: (bytes != null && bytes.isNotEmpty) ? bytes : null,
      );
    });
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<_ImageBytesResult> _loadImageBytesForSaving(int index) async {
    final alreadyDownloaded = _downloadedImages[index];
    if (alreadyDownloaded != null) {
      return alreadyDownloaded;
    }
    if (index < 0 || index >= _resolvedItems.length) {
      throw Exception('图片不存在');
    }
    final item = _resolvedItems[index];

    // 1. 优先从内存字节读取
    if (item.bytes != null && item.bytes!.isNotEmpty) {
      final ext = _guessExtensionFromBytes(item.bytes!, 'png');
      return _ImageBytesResult(item.bytes!, '原图', ext, _guessMimeType(ext));
    }

    // 2. 优先从本地文件读取
    if (item.localPath != null && item.localPath!.isNotEmpty) {
      final file = File(item.localPath!);
      if (await file.exists()) {
        final fileBytes = await file.readAsBytes();
        if (fileBytes.isNotEmpty) {
          final ext = _guessExtensionFromBytes(fileBytes, 'png');
          return _ImageBytesResult(fileBytes, '原图', ext, _guessMimeType(ext));
        }
      }
    }

    // 3. 网络图或缓存读取
    final url = item.url;
    if (url == null || url.isEmpty) {
      throw Exception('原图不可用，且本地文件不存在');
    }

    // 尝试直接下载原始字节
    try {
      final response = await Dio().get<List<int>>(
        url,
        options: Options(
          responseType: ResponseType.bytes,
          headers: widget.httpHeaders,
        ),
      );
      final data = response.data;
      if (data != null && data.isNotEmpty) {
        // 解析格式
        String ext = 'png'; // 默认
        final contentType = response.headers.value('content-type');
        if (contentType != null) {
          if (contentType.contains('jpeg') || contentType.contains('jpg')) {
            ext = 'jpg';
          } else if (contentType.contains('png')) {
            ext = 'png';
          } else if (contentType.contains('webp')) {
            ext = 'webp';
          } else if (contentType.contains('gif')) {
            ext = 'gif';
          }
        }
        ext = _guessExtensionFromBytes(data, ext);

        final bytes = Uint8List.fromList(data);
        return _ImageBytesResult(bytes, '原图', ext, _guessMimeType(ext));
      }
    } catch (_) {
      // 网络不可用
    }

    // 尝试本地缓存
    final cached = await _readCachedImage(url);
    if (cached != null) {
      final ext = _guessExtensionFromBytes(cached, 'png');
      return _ImageBytesResult(cached, '缓存原图', ext, _guessMimeType(ext));
    }

    // 最后才尝试渲染提取 (重编码为PNG)
    final visible = await _readVisibleImage(url);
    if (visible != null) {
      return _ImageBytesResult(visible, '重新编码图片', 'png', 'image/png');
    }

    throw Exception('原图不可用，且本机没有找到缓存');
  }

  Future<Uint8List?> _readVisibleImage(String url) async {
    final cacheKey =
        widget.cacheKeyBuilder != null ? widget.cacheKeyBuilder!(url) : null;
    final provider = CachedNetworkImageProvider(
      url,
      headers: widget.httpHeaders,
      cacheManager: widget.cacheManager ?? PostImageCache.manager,
      cacheKey: cacheKey,
    );
    final stream = provider.resolve(const ImageConfiguration());
    final completer = Completer<ui.Image?>();
    late ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        stream.removeListener(listener);
        completer.complete(info.image);
      },
      onError: (error, stackTrace) {
        stream.removeListener(listener);
        completer.complete(null);
      },
    );
    stream.addListener(listener);

    final image = await completer.future.timeout(
      const Duration(seconds: 2),
      onTimeout: () {
        stream.removeListener(listener);
        return null;
      },
    );
    if (image == null) return null;
    return _encodeImageForGallery(image);
  }

  Future<Uint8List> _encodeImageForGallery(ui.Image image) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final scale = math.min(
      1.0,
      _maxGalleryDimension /
          math.max(image.width.toDouble(), image.height.toDouble()),
    );
    final targetWidth = math.max(1, (image.width * scale).round());
    final targetHeight = math.max(1, (image.height * scale).round());
    final sourceRect = Rect.fromLTWH(
      0,
      0,
      image.width.toDouble(),
      image.height.toDouble(),
    );
    final targetRect = Rect.fromLTWH(
      0,
      0,
      targetWidth.toDouble(),
      targetHeight.toDouble(),
    );
    canvas.drawColor(Colors.white, BlendMode.src);
    canvas.drawImageRect(
      image,
      sourceRect,
      targetRect,
      Paint()..filterQuality = FilterQuality.medium,
    );
    final picture = recorder.endRecording();
    final flattened = await picture.toImage(targetWidth, targetHeight);
    final byteData = await flattened.toByteData(format: ui.ImageByteFormat.png);
    flattened.dispose();
    picture.dispose();
    if (byteData == null) {
      throw Exception('图片编码失败');
    }
    return byteData.buffer.asUint8List();
  }

  Future<Uint8List?> _readCachedImage(String url) async {
    final cacheKey =
        widget.cacheKeyBuilder != null ? widget.cacheKeyBuilder!(url) : url;

    // 如果指定了私有/自定义 cacheManager，则严格只从该管理器按 cacheKey 读取，
    // 绝不回退到 PostImageCache 或 DefaultCacheManager，防止私信账号隔离被旁路。
    if (widget.cacheManager != null) {
      final fileInfo = await widget.cacheManager!.getFileFromCache(cacheKey);
      final file = fileInfo?.file;
      if (file != null && await file.exists()) {
        final bytes = await file.readAsBytes();
        if (bytes.isNotEmpty) return bytes;
      }
      return null;
    }

    // 未指定 cacheManager（公开帖子/公开图片），使用公开缓存与默认缓存回退
    final cacheManagers = <BaseCacheManager>[
      PostImageCache.manager,
      DefaultCacheManager(),
    ];

    for (final cacheManager in cacheManagers) {
      final fileInfo = await cacheManager.getFileFromCache(cacheKey);
      final file = fileInfo?.file;
      if (file != null && await file.exists()) {
        final bytes = await file.readAsBytes();
        if (bytes.isNotEmpty) return bytes;
      }
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
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('需要相册权限才能保存图片')));
          if (mounted) setState(() => _isSaving = false);
          return;
        }
      }

      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('正在保存图片，原图不可用时会尝试本地缓存...')));

      final image = await _loadImageBytesForSaving(_currentIndex);
      final extension = switch (image.extension.toLowerCase()) {
        'jpg' || 'jpeg' => 'jpg',
        'png' => 'png',
        'webp' => 'webp',
        'gif' => 'gif',
        _ => 'png',
      };

      final String filename =
          'sylulive_${DateTime.now().millisecondsSinceEpoch}.$extension';

      final tempDir = await getTemporaryDirectory();
      final tempPath = '${tempDir.path}/$filename';
      final file = File(tempPath);
      await file.writeAsBytes(image.bytes, flush: true);

      await Gal.putImage(tempPath, album: '沈理');

      if (!mounted) return;
      setState(() {
        _rememberDownloadedImage(_currentIndex, image);
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('${image.sourceLabel}已保存到"沈理"相册')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('保存失败: $e')));
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
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
          : PageView.builder(
              controller: _pageController,
              itemCount: total,
              onPageChanged: (index) {
                if (mounted) {
                  setState(() {
                    _currentIndex = index;
                  });
                }
              },
              itemBuilder: (context, index) {
                return GestureDetector(
                  onLongPress: () {
                    showModalBottomSheet(
                      context: context,
                      backgroundColor: Colors.transparent,
                      builder: (context) => Container(
                        margin: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Theme.of(context).brightness == Brightness.dark
                              ? const Color(0xFF1E1E1E)
                              : Colors.white,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ListTile(
                              leading: const Icon(Icons.download),
                              title: const Text('保存原图'),
                              onTap: () {
                                Navigator.pop(context);
                                _saveImage();
                              },
                            ),
                            ListTile(
                              leading: const Icon(Icons.close),
                              title: const Text('取消'),
                              onTap: () => Navigator.pop(context),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                  child: InteractiveViewer(
                    child: Center(
                      child: _buildPageImage(index),
                    ),
                  ),
                );
              },
            ),
    );
  }

  /// 单页图片来源优先级：内存字节 → 本地文件 → 已下载内存 → 鉴权网络。
  Widget _buildPageImage(int index) {
    if (index < 0 || index >= _resolvedItems.length) {
      return const Icon(Icons.error, color: Colors.white, size: 48);
    }
    final item = _resolvedItems[index];
    final cacheDimension = _imageCacheDimension();

    // 优先级 1：内存字节
    if (item.bytes != null && item.bytes!.isNotEmpty) {
      return Image.memory(
        item.bytes!,
        fit: BoxFit.contain,
        cacheWidth: cacheDimension,
        cacheHeight: cacheDimension,
      );
    }

    // 优先级 2：本地文件
    final localPath = item.localPath;
    if (localPath != null && localPath.isNotEmpty) {
      return Image.file(
        File(localPath),
        fit: BoxFit.contain,
        cacheWidth: cacheDimension,
        cacheHeight: cacheDimension,
        errorBuilder: (_, __, ___) => _networkImageView(item.url),
      );
    }

    // 优先级 3：已下载内存
    if (_downloadedImages.containsKey(index)) {
      return Image.memory(
        _downloadedImages[index]!.bytes,
        fit: BoxFit.contain,
        cacheWidth: cacheDimension,
        cacheHeight: cacheDimension,
      );
    }

    // 优先级 4：网络
    return _networkImageView(item.url);
  }

  Widget _networkImageView(String? url) {
    if (url == null || url.isEmpty) {
      return const Icon(Icons.error, color: Colors.white, size: 48);
    }
    final cacheDimension = _imageCacheDimension();
    final cacheKey =
        widget.cacheKeyBuilder != null ? widget.cacheKeyBuilder!(url) : null;
    return CachedNetworkImage(
      cacheManager: widget.cacheManager ?? PostImageCache.manager,
      imageUrl: url,
      cacheKey: cacheKey,
      httpHeaders: widget.httpHeaders,
      fit: BoxFit.contain,
      memCacheWidth: cacheDimension,
      memCacheHeight: cacheDimension,
      placeholder: (context, url) => const Center(
        child: CircularProgressIndicator(color: Colors.white),
      ),
      errorWidget: (context, url, error) => const Icon(
        Icons.error,
        color: Colors.white,
        size: 48,
      ),
    );
  }

  int _imageCacheDimension() {
    final size = MediaQuery.sizeOf(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final logicalDimension = math.max(size.width, size.height);
    return (logicalDimension * dpr * 1.5).ceil().clamp(1024, 2048).toInt();
  }

  void _rememberDownloadedImage(int index, _ImageBytesResult image) {
    _downloadedImages[index] = image;
    while (_downloadedImages.length > _maxDownloadedImageEntries) {
      _downloadedImages.remove(_downloadedImages.keys.first);
    }
  }
}
