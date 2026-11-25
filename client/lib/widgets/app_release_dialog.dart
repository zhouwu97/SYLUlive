import 'package:flutter/material.dart';

import '../models/app_update_info.dart';
import '../theme/app_radius.dart';
import '../theme/app_theme_tokens.dart';
import 'app_dialog.dart';

const appReleaseDownloadPage = 'https://github.com/zhouwu97/SYLUlive/releases';

/// 正式版与 Beta 共用排版和材质，通道行为由各自弹窗处理。
class AppReleaseDialog extends StatelessWidget {
  const AppReleaseDialog({
    super.key,
    required this.info,
    required this.badge,
    required this.subtitle,
    required this.icon,
    required this.title,
    required this.notice,
    required this.notesTitle,
    required this.emptyNotes,
    required this.bottomNote,
    required this.footer,
    this.onClose,
  });

  final AppUpdateInfo info;
  final String badge;
  final String subtitle;
  final IconData icon;
  final String title;
  final Widget notice;
  final String notesTitle;
  final String emptyNotes;
  final String bottomNote;
  final Widget footer;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeTokens.of(context);
    final muted = Color.lerp(colors.textPrimary, colors.surface, 0.35)!;
    final external = info.deliveryMode == AppUpdateDeliveryMode.externalMarket;
    final version = info.latestVersionName.startsWith('v')
        ? info.latestVersionName
        : 'v${info.latestVersionName}';
    final paragraphs = info.changelog.trim().isEmpty
        ? [emptyNotes]
        : info.changelog
            .split('\n')
            .map((line) => line.trim())
            .where((line) => line.isNotEmpty)
            .map((line) => line.replaceFirst(RegExp(r'^[-*•]\s+'), ''))
            .toList();
    return AppDialog(
      backgroundColor: colors.surface,
      surfaceTintColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(24),
      constraints: const BoxConstraints(maxWidth: 342),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.sheet),
        side: BorderSide(color: colors.outline.withValues(alpha: 0.65)),
      ),
      child: Semantics(
        namesRoute: true,
        label: info.isBeta ? 'Beta 测试版下载' : title,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: info.isBeta
                ? LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      colors.primary
                          .withValues(alpha: colors.isDark ? 0.08 : 0.045),
                      Colors.transparent,
                    ],
                    stops: const [0, 0.45],
                  )
                : null,
          ),
          child: SizedBox(
            width: 342,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  fit: FlexFit.loose,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                color: colors.primaryContainer,
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child:
                                  Icon(icon, size: 24, color: colors.primary),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 12, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: colors.primaryContainer,
                                      borderRadius:
                                          BorderRadius.circular(AppRadius.pill),
                                    ),
                                    child: Text(badge,
                                        style: TextStyle(
                                            fontSize: 10.5,
                                            height: 1.35,
                                            letterSpacing: 0.5,
                                            fontWeight: FontWeight.w600,
                                            color: colors.primary)),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(subtitle,
                                      style: TextStyle(
                                          fontSize: 12,
                                          height: 1.4,
                                          fontWeight: FontWeight.w400,
                                          color: muted)),
                                ],
                              ),
                            ),
                            if (onClose != null)
                              IconButton(
                                tooltip: '关闭',
                                onPressed: onClose,
                                style: IconButton.styleFrom(
                                    foregroundColor: muted,
                                    padding: EdgeInsets.zero,
                                    minimumSize: const Size(44, 44)),
                                icon: Container(
                                  width: 30,
                                  height: 30,
                                  decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: colors.primaryContainer),
                                  child:
                                      const Icon(Icons.close_rounded, size: 20),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 22,
                              height: 1.3,
                              fontWeight: FontWeight.w600,
                              color: colors.textPrimary),
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 12,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(version,
                                style: TextStyle(
                                    fontSize: 13,
                                    height: 1.4,
                                    fontWeight: FontWeight.w400,
                                    color: muted)),
                            if (!external)
                              Text('·  ${formatReleaseSize(info.fileSize)}',
                                  style: TextStyle(
                                      fontSize: 13,
                                      height: 1.4,
                                      fontWeight: FontWeight.w400,
                                      color: muted)),
                          ],
                        ),
                        const SizedBox(height: 18),
                        notice,
                        const SizedBox(height: 18),
                        Divider(height: 1, color: colors.divider),
                        const SizedBox(height: 20),
                        Text(notesTitle,
                            style: TextStyle(
                                fontSize: 13,
                                height: 1.4,
                                fontWeight: FontWeight.w600,
                                color: colors.textPrimary)),
                        const SizedBox(height: 12),
                        for (var i = 0; i < paragraphs.length; i++) ...[
                          if (i > 0) const SizedBox(height: 12),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: colors.primary
                                          .withValues(alpha: 0.7)),
                                  child: const SizedBox(width: 5, height: 5),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(paragraphs[i],
                                    style: TextStyle(
                                        fontSize: 14,
                                        height: 1.55,
                                        fontWeight: FontWeight.w400,
                                        color: colors.textPrimary)),
                              ),
                            ],
                          ),
                        ],
                        const SizedBox(height: 18),
                        Text(bottomNote,
                            style: TextStyle(
                                fontSize: 12,
                                height: 1.5,
                                fontWeight: FontWeight.w400,
                                color: muted)),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
                  child: footer,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String formatReleaseSize(int bytes) {
  if (bytes >= 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '$bytes B';
}
