import 'package:flutter/material.dart';

class WaterPostBottomBar extends StatelessWidget {
  final bool isLoading;
  final int imageCount;
  final int maxImages;
  final int charCount;
  final int maxContentLength;
  final String publishLabel;
  final VoidCallback? onPublish;

  const WaterPostBottomBar({
    super.key,
    required this.isLoading,
    required this.imageCount,
    required this.maxImages,
    required this.charCount,
    required this.maxContentLength,
    required this.publishLabel,
    required this.onPublish,
  });

  static const Color _publishColor = Color(0xFF5861F2);

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final borderColor =
        isDark ? Colors.white.withValues(alpha: 0.08) : const Color(0xFFEDEFF3);
    final textColor = isDark ? Colors.white54 : const Color(0xFF9AA0A6);

    return SafeArea(
      top: false,
      child: Container(
        color: isDark ? const Color(0xFF0D1117) : Colors.white,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: borderColor)),
              ),
              child: Row(
                children: [
                  Text(
                    '图片 $imageCount/$maxImages',
                    style: TextStyle(fontSize: 13, color: textColor),
                  ),
                  const Spacer(),
                  Text(
                    '$charCount/$maxContentLength字',
                    style: TextStyle(fontSize: 13, color: textColor),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: SizedBox(
                width: double.infinity,
                height: 52,
                child: FilledButton(
                  onPressed: isLoading ? null : onPublish,
                  style: FilledButton.styleFrom(
                    backgroundColor: _publishColor,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: _publishColor.withValues(
                      alpha: 0.48,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  child: isLoading
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : Text(
                          publishLabel,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
