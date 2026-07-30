import 'package:flutter/material.dart';

import '../features/personal_data_sync/erke_snapshot_upload.dart';

Future<ErkeSnapshotUploadPolicy?> showErkeSnapshotUploadDialog(
  BuildContext context,
) {
  return showDialog<ErkeSnapshotUploadPolicy>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => const ErkeSnapshotUploadDialog(),
  );
}

class ErkeSnapshotUploadDialog extends StatelessWidget {
  const ErkeSnapshotUploadDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final mutedColor = colors.onSurfaceVariant;

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: colors.primaryContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      Icons.cloud_upload_outlined,
                      color: colors.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '是否上传二课摘要？',
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '由你决定，之后可以修改',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: mutedColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Text(
                '上传后，校园 Agent 可以结合二课进度提供更准确的建议。',
                style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
              ),
              const SizedBox(height: 14),
              _DataScopeRow(
                icon: Icons.check_circle_outline_rounded,
                iconColor: colors.primary,
                title: '仅上传摘要',
                detail: '分数汇总、分类缺口、最近活动',
              ),
              const SizedBox(height: 10),
              _DataScopeRow(
                icon: Icons.shield_outlined,
                iconColor: colors.tertiary,
                title: '敏感信息留在本机',
                detail: '密码、Cookie、会话、页面原文',
              ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: colors.secondaryContainer.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.info_outline_rounded,
                      size: 18,
                      color: colors.onSecondaryContainer,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '选择自动上传后，每次更新二课都会同步摘要；可在个人数据保险箱随时关闭或删除。',
                        style: theme.textTheme.bodySmall?.copyWith(
                          height: 1.45,
                          color: colors.onSecondaryContainer,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              SizedBox(
                height: 44,
                child: FilledButton.icon(
                  key: const ValueKey('erke-upload-once'),
                  onPressed: () => Navigator.pop(
                    context,
                    ErkeSnapshotUploadPolicy.uploadThisTime,
                  ),
                  icon: const Icon(Icons.upload_rounded, size: 19),
                  label: const Text('仅本次上传'),
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                height: 44,
                child: OutlinedButton.icon(
                  key: const ValueKey('erke-upload-auto'),
                  onPressed: () => Navigator.pop(
                    context,
                    ErkeSnapshotUploadPolicy.autoUploadSummary,
                  ),
                  icon: const Icon(Icons.sync_rounded, size: 19),
                  label: const Text('之后自动上传'),
                ),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      key: const ValueKey('erke-upload-later'),
                      onPressed: () => Navigator.pop(
                        context,
                        ErkeSnapshotUploadPolicy.askEveryUpdate,
                      ),
                      child: const Text('下次再问'),
                    ),
                  ),
                  SizedBox(
                    height: 20,
                    child: VerticalDivider(color: colors.outlineVariant),
                  ),
                  Expanded(
                    child: TextButton(
                      key: const ValueKey('erke-upload-never'),
                      onPressed: () => Navigator.pop(
                        context,
                        ErkeSnapshotUploadPolicy.neverUpload,
                      ),
                      child: const Text('永不上传'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DataScopeRow extends StatelessWidget {
  const _DataScopeRow({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.detail,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(icon, size: 20, color: iconColor),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 1),
              Text(
                detail,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
