import 'package:flutter/material.dart';
import '../../config/api_constants.dart';
import '../../screens/image_viewer_screen.dart';
import 'canteen_status_image.dart';

/// 菜品实拍三图布局：
/// - 1 张：全宽大图（4:3）
/// - 2 张：左右各半
/// - 3 张：1 大 + 2 小
class DishPhotoMosaic extends StatefulWidget {
  final List<String> imageUrls;
  final bool offline;
  final void Function(int index)? onLongPress;
  final ValueChanged<String>? onImageError;

  const DishPhotoMosaic({
    super.key,
    required this.imageUrls,
    this.offline = false,
    this.onLongPress,
    this.onImageError,
  });

  @override
  State<DishPhotoMosaic> createState() => _DishPhotoMosaicState();
}

class _DishPhotoMosaicState extends State<DishPhotoMosaic> {
  final Set<String> _failedUrls = <String>{};

  void _hideFailedImage(String sourceUrl) {
    if (_failedUrls.contains(sourceUrl)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _failedUrls.contains(sourceUrl)) return;
      setState(() => _failedUrls.add(sourceUrl));
      widget.onImageError?.call(sourceUrl);
    });
  }

  @override
  Widget build(BuildContext context) {
    final sources = widget.imageUrls
        .map((url) => url.trim())
        .where((url) => url.isNotEmpty && !_failedUrls.contains(url))
        .toList(growable: false);
    if (sources.isEmpty) {
      return const SizedBox.shrink();
    }
    final urls = sources.map(ApiConstants.fullUrl).toList(growable: false);
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: switch (urls.length) {
        1 => _buildLarge(sources, urls, context, 0),
        2 => Row(
            children: [
              Expanded(child: _buildTile(sources, urls, context, 220, 0)),
              const SizedBox(width: 4),
              Expanded(child: _buildTile(sources, urls, context, 220, 1)),
            ],
          ),
        _ => Column(
            children: [
              _buildLarge(sources, urls, context, 0),
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(child: _buildTile(sources, urls, context, 160, 1)),
                  const SizedBox(width: 4),
                  Expanded(child: _buildTile(sources, urls, context, 160, 2)),
                ],
              ),
            ],
          ),
      },
    );
  }

  Widget _buildLarge(List<String> sources, List<String> urls,
      BuildContext context, int index) {
    return _buildTile(sources, urls, context, 240, index);
  }

  Widget _buildTile(
      List<String> sources,
      List<String> urls,
      BuildContext context,
      double height,
      int index) {
    final url = urls[index];
    final sourceUrl = sources[index];
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
      onLongPress: widget.onLongPress != null
          ? () => widget.onLongPress!(index)
          : null,
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: CanteenStatusImage(
          imageUrl: url,
          variant: 'medium',
          offline: widget.offline,
          fit: BoxFit.cover,
          errorWidget: (_, __, ___) {
            _hideFailedImage(sourceUrl);
            return const SizedBox.shrink();
          },
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
