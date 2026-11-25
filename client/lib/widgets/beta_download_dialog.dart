import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/app_update_info.dart';
import '../platform/contracts/external_navigator.dart';
import '../services/app_update_coordinator.dart';
import '../theme/app_theme_tokens.dart';
import 'app_dialog.dart';
import 'app_release_dialog.dart';

Future<void> showBetaDownloadDialog(
    BuildContext context, AppUpdateCoordinator coordinator, AppUpdateInfo info,
    {bool callerOwnsPrompt = false}) async {
  if (!callerOwnsPrompt && !coordinator.tryBeginPrompt()) return;
  try {
    coordinator.deferBetaDownload();
    await showAppDialog<void>(
      context: context,
      builder: (dialogContext) {
        final current = dialogContext.watch<AppUpdateCoordinator>();
        if (current.betaInfo?.releaseKey != info.releaseKey ||
            current.isRequired ||
            current.shouldPromptInstall) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (dialogContext.mounted &&
                ModalRoute.of(dialogContext)?.isCurrent == true) {
              Navigator.of(dialogContext).pop();
            }
          });
        }
        return BetaDownloadDialog(info: info);
      },
    );
  } finally {
    if (!callerOwnsPrompt) coordinator.endPrompt();
  }
}

/// Beta 只打开下载链接，不进入正式版的下载任务和安装流程。
class BetaDownloadDialog extends StatefulWidget {
  const BetaDownloadDialog({super.key, required this.info});

  final AppUpdateInfo info;

  @override
  State<BetaDownloadDialog> createState() => _BetaDownloadDialogState();
}

class _BetaDownloadDialogState extends State<BetaDownloadDialog> {
  bool _opening = false;
  String? _linkError;

  Future<void> _openDownload({bool github = false}) async {
    if (_opening) return;
    setState(() {
      _opening = true;
      _linkError = null;
    });
    try {
      final url = github
          ? appReleaseDownloadPage
          : widget.info.deliveryMode == AppUpdateDeliveryMode.externalMarket
              ? widget.info.actionUrl
              : widget.info.downloadUrl;
      final opened = await ExternalNavigator.current().open(Uri.parse(url));
      if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
      if (opened) {
        Navigator.of(context).pop();
      } else {
        setState(() => _linkError = '无法打开下载链接，请重试');
      }
    } catch (_) {
      if (mounted) setState(() => _linkError = '无法打开下载链接，请重试');
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeTokens.of(context);
    return AppReleaseDialog(
      info: widget.info,
      badge: 'BETA 测试版',
      subtitle: '提前体验新功能',
      icon: Icons.download_outlined,
      title:
          widget.info.title.trim().isEmpty ? '下载 Beta 测试版' : widget.info.title,
      onClose: () => Navigator.of(context).pop(),
      notice: _notice(colors),
      notesTitle: '功能与说明',
      emptyNotes: '更多功能与体验说明请查看测试版发布页。',
      bottomNote: '由浏览器打开下载链接，下载后可自行决定是否安装。',
      footer: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          LayoutBuilder(builder: (context, constraints) {
            final secondary = TextButton(
              onPressed: () => Navigator.of(context).pop(),
              style: TextButton.styleFrom(
                  foregroundColor: colors.textPrimary,
                  backgroundColor: colors.surfaceMuted,
                  minimumSize: const Size.fromHeight(48),
                  visualDensity: VisualDensity.standard,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(13))),
              child: const Text('暂不下载',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
            );
            final primary = _primary(colors);
            if (constraints.maxWidth < 280 ||
                MediaQuery.textScalerOf(context).scale(14) > 18) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  primary,
                  const SizedBox(height: 12),
                  secondary,
                ],
              );
            }
            return Row(children: [
              SizedBox(width: 96, child: secondary),
              const SizedBox(width: 12),
              Expanded(child: primary),
            ]);
          }),
          if (_linkError != null) ...[
            const SizedBox(height: 10),
            Semantics(
                liveRegion: true,
                child: Text(_linkError!,
                    style: TextStyle(
                        fontSize: 12, height: 1.4, color: colors.error))),
          ],
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: _opening ? null : () => _openDownload(github: true),
            style: TextButton.styleFrom(
                foregroundColor: colors.primary,
                minimumSize: const Size(0, 40)),
            iconAlignment: IconAlignment.end,
            icon: const Icon(Icons.north_east_rounded, size: 14),
            label: const Text('GitHub 下载', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  Widget _notice(AppThemeTokens colors) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: colors.primaryContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outline_rounded, size: 18, color: colors.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Beta 版提供更丰富的功能，但仍处于测试阶段，不建议小白用户下载，推荐继续使用正式版。',
                style: TextStyle(
                    fontSize: 13,
                    height: 1.55,
                    fontWeight: FontWeight.w500,
                    color: colors.textPrimary),
              ),
            ),
          ],
        ),
      );

  Widget _primary(AppThemeTokens colors) => FilledButton.icon(
        onPressed: _opening ? null : _openDownload,
        style: FilledButton.styleFrom(
            foregroundColor: colors.onPrimary,
            backgroundColor: colors.primary,
            minimumSize: const Size.fromHeight(48),
            visualDensity: VisualDensity.standard,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(13))),
        icon: const Icon(Icons.download_outlined, size: 18),
        label: Text(_opening ? '正在打开…' : '下载 Beta 版',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
      );
}
