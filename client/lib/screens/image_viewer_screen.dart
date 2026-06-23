import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';

import '../utils/post_image_cache.dart';

class ImageViewerScreen extends StatefulWidget {
  final List<String> imageUrls;
  final int initialIndex;

  const ImageViewerScreen({
    super.key,
    required this.imageUrls,
    this.initialIndex = 0,
  });

  @override
  State<ImageViewerScreen> createState() => _ImageViewerScreenState();
}

class _ImageBytesResult {
  final Uint8List bytes;
  final String sourceLabel;

  const _ImageBytesResult(this.bytes, this.sourceLabel);
}

class _ImageViewerScreenState extends State<ImageViewerScreen> {
  late PageController _pageController;
  late int _currentIndex;
  bool _isSaving = false;
  final Map<int, Uint8List> _downloadedImages = {};

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: widget.initialIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<_ImageBytesResult> _loadImageBytesForSaving(String url) async {
    final alreadyDownloaded = _downloadedImages[_currentIndex];
    if (alreadyDownloaded != null) {
      return _ImageBytesResult(alreadyDownloaded, '当前图片');
    }

    try {
      final response = await Dio().get<List<int>>(
        url,
        options: Options(responseType: ResponseType.bytes),
      );
      final data = response.data;
      if (data != null && data.isNotEmpty) {
        return _ImageBytesResult(await _normalizeImageBytes(data), '原图');
      }
    } catch (_) {
      // 网络原图不可用时继续尝试本地缓存，典型场景是服务器文件丢失但手机曾经看过这张图。
    }

    final visible = await _readVisibleImage(url);
    if (visible != null) {
      return _ImageBytesResult(visible, '当前显示图片');
    }

    final cached = await _readCachedImage(url);
    if (cached != null) {
      return _ImageBytesResult(await _normalizeImageBytes(cached), '缓存图');
    }

    throw Exception('原图不可用，且本机没有找到缓存');
  }

  Future<Uint8List> _normalizeImageBytes(List<int> bytes) async {
    final codec = await ui.instantiateImageCodec(Uint8List.fromList(bytes));
    final frame = await codec.getNextFrame();
    return _encodeImageForGallery(frame.image);
  }

  Future<Uint8List?> _readVisibleImage(String url) async {
    final provider = CachedNetworkImageProvider(
      url,
      cacheManager: PostImageCache.manager,
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
    final size = Size(image.width.toDouble(), image.height.toDouble());
    canvas.drawColor(Colors.white, BlendMode.src);
    canvas.drawImage(image, Offset.zero, Paint());
    final picture = recorder.endRecording();
    final flattened = await picture.toImage(
      size.width.toInt(),
      size.height.toInt(),
    );
    final byteData = await flattened.toByteData(format: ui.ImageByteFormat.png);
    if (byteData == null) {
      throw Exception('图片编码失败');
    }
    return byteData.buffer.asUint8List();
  }

  Future<Uint8List?> _readCachedImage(String url) async {
    final cacheManagers = <BaseCacheManager>[
      PostImageCache.manager,
      DefaultCacheManager(),
    ];

    for (final cacheManager in cacheManagers) {
      final fileInfo = await cacheManager.getFileFromCache(url);
      final file = fileInfo?.file;
      if (file != null && await file.exists()) {
        final bytes = await file.readAsBytes();
        if (bytes.isNotEmpty) return bytes;
      }
    }
    return null;
  }

  Future<void> _saveImage() async {
    if (_isSaving) return;
    if (mounted) setState(() => _isSaving = true);

    try {
      final String url = widget.imageUrls[_currentIndex];

      final hasAccess = await Gal.hasAccess();
      if (!hasAccess) {
        final request = await Gal.requestAccess();
        if (!request) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('需要相册权限才能保存图片')),
          );
          if (mounted) setState(() => _isSaving = false);
          return;
        }
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('正在保存图片，原图不可用时会尝试本地缓存...')),
      );

      final image = await _loadImageBytesForSaving(url);
      final String filename =
          'sylulive_${DateTime.now().millisecondsSinceEpoch}.png';

      final tempDir = await getTemporaryDirectory();
      final tempPath = '${tempDir.path}/$filename';
      final file = File(tempPath);
      await file.writeAsBytes(image.bytes);

      await Gal.putImage(tempPath, album: '沈理');

      if (!mounted) return;
      setState(() {
        _downloadedImages[_currentIndex] = image.bytes;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${image.sourceLabel}已保存到"沈理"相册')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存失败: $e')),
      );
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Text(
          '${_currentIndex + 1} / ${widget.imageUrls.length}',
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
            onPressed: _saveImage,
          ),
        ],
      ),
      body: PageView.builder(
        controller: _pageController,
        itemCount: widget.imageUrls.length,
        onPageChanged: (index) {
          if (mounted) {
            setState(() {
              _currentIndex = index;
            });
          }
        },
        itemBuilder: (context, index) {
          return InteractiveViewer(
            child: Center(
              child: _downloadedImages.containsKey(index)
                  ? Image.memory(
                      _downloadedImages[index]!,
                      fit: BoxFit.contain,
                    )
                  : CachedNetworkImage(
                      cacheManager: PostImageCache.manager,
                      imageUrl: widget.imageUrls[index],
                      fit: BoxFit.contain,
                      placeholder: (context, url) => const Center(
                        child: CircularProgressIndicator(color: Colors.white),
                      ),
                      errorWidget: (context, url, error) => const Icon(
                        Icons.error,
                        color: Colors.white,
                        size: 48,
                      ),
                    ),
            ),
          );
        },
      ),
    );
  }
}
