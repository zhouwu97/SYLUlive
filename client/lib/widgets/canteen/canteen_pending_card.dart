import 'package:flutter/material.dart';

import '../../config/api_constants.dart';
import '../../screens/image_viewer_screen.dart';
import '../../theme/app_colors.dart';
import 'canteen_status_image.dart';

/// 待审核食堂卡片：提交图缩略图（可点开全屏）+ 名称 + 提交人 + 时间 + 通过/驳回。
class CanteenPendingCard extends StatelessWidget {
  final Map<String, dynamic> canteen;
  final bool isDark;
  final Future<void> Function()? onApprove;
  final Future<void> Function()? onReject;

  const CanteenPendingCard({
    super.key,
    required this.canteen,
    required this.isDark,
    this.onApprove,
    this.onReject,
  });

  @override
  Widget build(BuildContext context) {
    final image = (canteen['image'] ?? '').toString();
    final creator = (canteen['creator_name'] ?? '').toString();
    final name = (canteen['name'] ?? '').toString();
    final createdAt =
        DateTime.tryParse((canteen['created_at'] ?? '').toString());
    String timeText = '';
    if (createdAt != null) {
      final local = createdAt.toLocal();
      timeText = '${local.year}/${local.month}/${local.day} '
          '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
    }

    final imageUrl = image.isEmpty ? '' : ApiConstants.fullUrl(image);

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      color: isDark ? Colors.grey[850] : Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        leading: _PendingThumbnail(imageUrl: imageUrl),
        title: Text(
          '新食堂：$name',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          '提交人：${creator.isEmpty ? '未知用户' : creator}'
          '${timeText.isEmpty ? '' : '\n提交时间：$timeText'}'
          '${image.isEmpty ? '\n（未上传门面图）' : ''}',
        ),
        isThreeLine: timeText.isNotEmpty || image.isEmpty,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: '审核通过',
              icon: const Icon(Icons.check_circle, color: Colors.green),
              onPressed: onApprove,
            ),
            IconButton(
              tooltip: '驳回',
              icon: const Icon(Icons.cancel, color: Colors.red),
              onPressed: onReject,
            ),
          ],
        ),
      ),
    );
  }
}

class _PendingThumbnail extends StatefulWidget {
  final String imageUrl;

  const _PendingThumbnail({required this.imageUrl});

  @override
  State<_PendingThumbnail> createState() => _PendingThumbnailState();
}

class _PendingThumbnailState extends State<_PendingThumbnail> {
  void _openViewer() {
    if (widget.imageUrl.isEmpty) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ImageViewerScreen(imageUrls: [widget.imageUrl]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: _openViewer,
      borderRadius: BorderRadius.circular(10),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          width: 56,
          height: 56,
          child: widget.imageUrl.isEmpty
              ? _placeholderIcon(
                  Icons.image_not_supported_outlined, Colors.grey)
              : CanteenStatusImage(
                  imageUrl: widget.imageUrl,
                  variant: 'thumb',
                  fit: BoxFit.cover,
                  placeholder: (_, __) => Container(
                    color: AppColors.brandPrimary.withValues(alpha: 0.15),
                    child: const Center(
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  ),
                  errorWidget: (_, __, ___) => _placeholderIcon(
                    Icons.broken_image_outlined,
                    Colors.orange,
                  ),
                ),
        ),
      ),
    );
  }

  Widget _placeholderIcon(IconData icon, Color color) {
    return Container(
      color: AppColors.brandPrimary.withValues(alpha: 0.15),
      child: Icon(icon, color: color),
    );
  }
}
