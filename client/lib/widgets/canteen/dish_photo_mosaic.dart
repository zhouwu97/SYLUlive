import 'package:flutter/material.dart';
import '../../config/api_constants.dart';
import '../../screens/image_viewer_screen.dart';
import 'canteen_status_image.dart';

/// 菜品实拍三图布局：
/// - 1 张：全宽大图（4:3）
/// - 2 张：左右各半
/// - 3 张：1 大 + 2 小
class DishPhotoMosaic extends StatelessWidget {
  final List<String> imageUrls;
  final bool offline;
  final void Function(int index)? onLongPress;

  const DishPhotoMosaic({
    super.key,
    required this.imageUrls,
    this.offline = false,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    if (imageUrls.isEmpty) {
      return const SizedBox.shrink();
    }
    final urls = imageUrls.map((u) => ApiConstants.fullUrl(u)).toList();
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: switch (urls.length) {
        1 => _buildLarge(urls, context, 0),
        2 => Row(
            children: [
              Expanded(child: _buildTile(urls, context, 220, 0)),
              const SizedBox(width: 4),
              Expanded(child: _buildTile(urls, context, 220, 1)),
            ],
          ),
        _ => Column(
            children: [
              _buildLarge(urls, context, 0),
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(child: _buildTile(urls, context, 160, 1)),
                  const SizedBox(width: 4),
                  Expanded(child: _buildTile(urls, context, 160, 2)),
                ],
              ),
            ],
          ),
      },
    );
  }

  Widget _buildLarge(List<String> urls, BuildContext context, int index) {
    return _buildTile(urls, context, 240, index);
  }

  Widget _buildTile(
      List<String> urls, BuildContext context, double height, int index) {
    final url = urls[index];
    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ImageViewerScreen(
              imageUrls: urls,
              initialIndex: index,
            ),
          ),
        );
      },
      onLongPress: onLongPress != null ? () => onLongPress!(index) : null,
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: CanteenStatusImage(
          imageUrl: url,
          variant: 'medium',
          offline: offline,
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
