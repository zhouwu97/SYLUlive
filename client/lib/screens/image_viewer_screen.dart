import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:photo_manager/photo_manager.dart';

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

  Future<void> _saveImage() async {
    if (_isSaving) return;
    if (mounted) setState(() => _isSaving = true);

    try {
      final String url = widget.imageUrls[_currentIndex];
      
      // 请求相册权限
      final PermissionState ps = await PhotoManager.requestPermissionExtend();
      if (!ps.isAuth) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('需要相册权限才能保存图片')),
        );
        if (mounted) setState(() => _isSaving = false);
        return;
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('正在下载并保存原图...')),
      );
      
      // 下载图片数据
      final response = await Dio().get(
        url,
        options: Options(responseType: ResponseType.bytes),
      );

      final Uint8List bytes = Uint8List.fromList(response.data);
      final String filename = 'sylulive_${DateTime.now().millisecondsSinceEpoch}.jpg';
      
      // 保存到相册
      final AssetEntity? result = await PhotoManager.editor.saveImage(
        bytes,
        title: filename,
        filename: filename,
      );

      if (!mounted) return;
      if (result != null) {
        setState(() {
          _downloadedImages[_currentIndex] = bytes;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('原图已保存到相册并替换当前显示')),
        );
      } else {
        throw Exception('保存失败');
      }
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
          if (mounted) setState(() {
            _currentIndex = index;
          });
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