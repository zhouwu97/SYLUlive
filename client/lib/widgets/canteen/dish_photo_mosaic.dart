import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../../config/api_constants.dart';
import '../../screens/image_viewer_screen.dart';

/// 菜品实拍三图布局：
/// - 1 张：全宽大图（4:3）
/// - 2 张：左右各半
/// - 3 张：1 大 + 2 小
class DishPhotoMosaic extends StatelessWidget {
  final List<String> imageUrls;

  const DishPhotoMosaic({super.key, required this.imageUrls});

  @override
  Widget build(BuildContext context) {
    if (imageUrls.isEmpty) {
      return const SizedBox.shrink();
    }
    final urls = imageUrls.map((u) => ApiConstants.fullUrl(u)).toList();
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: switch (urls.length) {
        1 => _buildLarge(urls[0], context),
        2 => Row(
            children: [
              Expanded(child: _buildTile(urls[0], context, 220)),
              const SizedBox(width: 4),
              Expanded(child: _buildTile(urls[1], context, 220)),
            ],
          ),
        _ => Column(
            children: [
              _buildLarge(urls[0], context),
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(child: _buildTile(urls[1], context, 160)),
                  const SizedBox(width: 4),
                  Expanded(child: _buildTile(urls[2], context, 160)),
                ],
              ),
            ],
          ),
      },
    );
  }

  Widget _buildLarge(String url, BuildContext context) {
    return _buildTile(url, context, 240);
  }

  Widget _buildTile(String url, BuildContext context, double height) {
    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ImageViewerScreen(
              imageUrls: [url],
              initialIndex: 0,
            ),
          ),
        );
      },
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: CachedNetworkImage(
          imageUrl: url,
          fit: BoxFit.cover,
          errorWidget: (_, __, ___) => _buildPlaceholder(),
          placeholder: (_, __) => _buildPlaceholder(),
        ),
      ),
    );
  }

  Widget _buildPlaceholder() {
    return Container(
      color: const Color(0xFFEDEFF2),
      alignment: Alignment.center,
      child: const Icon(
        Icons.restaurant_rounded,
        size: 32,
        color: Color(0xFF9FA7B5),
      ),
    );
  }
}
