import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';

import '../utils/app_feedback.dart';
import 'campus/campus_theme.dart';

const String kGroupChatNumber = '692905367';
const String kGroupChatQrAsset = 'assets/images/group_chat_qr.png';

Future<void> showGroupChatDialog(BuildContext context) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  const accent = CampusTheme.primary;
  final dialogBackground = isDark ? const Color(0xFF1E1E2E) : Colors.white;
  final titleColor = isDark ? Colors.white : const Color(0xFF2D3142);
  final labelColor = isDark ? Colors.white54 : const Color(0xFF9094A6);
  final descriptionColor = isDark ? Colors.white70 : const Color(0xFF4F5568);
  final valuePanelColor =
      isDark ? const Color(0x0AFFFFFF) : const Color(0x08000000);
  final valueBorderColor =
      isDark ? const Color(0x0DFFFFFF) : const Color(0x0D000000);

  return showDialog<void>(
    context: context,
    builder: (dialogContext) {
      return AlertDialog(
        backgroundColor: dialogBackground,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        title: Row(
          children: [
            const Icon(Icons.group_rounded, color: accent),
            const SizedBox(width: 8),
            Text('加入群聊', style: TextStyle(color: titleColor)),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Column(
                  children: [
                    InkWell(
                      borderRadius: BorderRadius.circular(16),
                      onTap: () => _handleDownload(context),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: SizedBox(
                          width: 280,
                          child: Image.asset(
                            kGroupChatQrAsset,
                            key: const ValueKey('group-chat-qr-image'),
                            fit: BoxFit.contain,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '点击二维码保存到相册',
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark ? Colors.white38 : Colors.black38,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Text(
                '软件 QQ 群',
                style: TextStyle(
                  fontSize: 13,
                  color: labelColor,
                ),
              ),
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: valuePanelColor,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: valueBorderColor),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.numbers_rounded,
                      size: 18,
                      color: accent,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        kGroupChatNumber,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.6,
                          color: titleColor,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Text(
                '扫码进群反馈问题、交流使用体验，也可以复制群号手动搜索加入。',
                style: TextStyle(
                  fontSize: 13,
                  height: 1.4,
                  color: descriptionColor,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            style: TextButton.styleFrom(foregroundColor: accent),
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('知道了'),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: accent,
              foregroundColor: Colors.white,
            ),
            onPressed: () {
              Clipboard.setData(const ClipboardData(text: kGroupChatNumber));
              Navigator.pop(dialogContext);
              AppFeedback.success('QQ群号已复制到剪贴板', context: context);
            },
            icon: const Icon(Icons.copy_rounded, size: 16),
            label: const Text('复制群号'),
          ),
        ],
      );
    },
  );
}

Future<void> _handleDownload(BuildContext context) async {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  const accent = CampusTheme.primary;
  final dialogBackground = isDark ? const Color(0xFF1E1E2E) : Colors.white;
  final titleColor = isDark ? Colors.white : const Color(0xFF2D3142);
  final contentColor = isDark ? Colors.white70 : const Color(0xFF4F5568);

  final confirm = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: dialogBackground,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
      ),
      title: Row(
        children: [
          const Icon(Icons.save_alt_rounded, color: accent),
          const SizedBox(width: 8),
          Text('保存二维码', style: TextStyle(color: titleColor)),
        ],
      ),
      content: Text(
        '是否将群聊二维码保存到手机相册？',
        style: TextStyle(
          color: contentColor,
          fontSize: 15,
        ),
      ),
      actions: [
        TextButton(
          style: TextButton.styleFrom(foregroundColor: accent),
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('取消'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: accent,
            foregroundColor: Colors.white,
          ),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('确定'),
        ),
      ],
    ),
  );

  if (confirm != true) return;

  try {
    if (!await Gal.hasAccess()) {
      final access = await Gal.requestAccess();
      if (!access) {
        if (!context.mounted) return;
        AppFeedback.error('需要相册权限才能保存图片', context: context);
        return;
      }
    }

    final byteData = await rootBundle.load(kGroupChatQrAsset);
    final bytes = byteData.buffer.asUint8List();
    await Gal.putImageBytes(bytes);

    if (!context.mounted) return;
    AppFeedback.success('已保存到相册', context: context);
  } catch (e) {
    if (!context.mounted) return;
    AppFeedback.error('保存失败: $e', context: context);
  }
}
