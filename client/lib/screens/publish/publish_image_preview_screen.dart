import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../config/api_constants.dart';
import '../../models/post.dart';

class PublishImagePreviewScreen extends StatefulWidget {
  final List<PostImage> existingImages;
  final List<XFile> selectedImages;
  final int initialIndex;

  const PublishImagePreviewScreen({
    super.key,
    required this.existingImages,
    required this.selectedImages,
    required this.initialIndex,
  });

  @override
  State<PublishImagePreviewScreen> createState() =>
      _PublishImagePreviewScreenState();
}

class _PublishImagePreviewScreenState extends State<PublishImagePreviewScreen> {
  late final PageController _controller;
  late int _index;

  int get _total => widget.existingImages.length + widget.selectedImages.length;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, _total - 1);
    _controller = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Widget _buildImage(int index) {
    final existingCount = widget.existingImages.length;
    if (index < existingCount) {
      final image = widget.existingImages[index];
      return CachedNetworkImage(
        imageUrl: ApiConstants.fullUrl(image.url),
        fit: BoxFit.contain,
        placeholder: (_, __) =>
            const Center(child: CircularProgressIndicator()),
        errorWidget: (_, __, ___) => const Icon(Icons.broken_image_rounded,
            color: Colors.white, size: 48),
      );
    }

    final file = widget.selectedImages[index - existingCount];
    return Image.file(
      File(file.path),
      fit: BoxFit.contain,
      errorBuilder: (_, __, ___) =>
          const Icon(Icons.broken_image_rounded, color: Colors.white, size: 48),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text('${_index + 1} / $_total'),
      ),
      body: PageView.builder(
        controller: _controller,
        itemCount: _total,
        onPageChanged: (value) => setState(() => _index = value),
        itemBuilder: (context, index) {
          return InteractiveViewer(
            minScale: 1,
            maxScale: 4,
            child: Center(child: _buildImage(index)),
          );
        },
      ),
    );
  }
}
