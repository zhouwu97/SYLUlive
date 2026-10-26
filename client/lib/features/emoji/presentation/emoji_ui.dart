import 'package:shenliyuan/widgets/app_dialog.dart';
import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';
import '../../../theme/app_radius.dart';
import '../../../theme/app_spacing.dart';
import '../../../widgets/app_page_app_bar.dart';
import '../../../widgets/app_page_background.dart';
import '../../../widgets/campus/campus_theme.dart';
import '../../../widgets/responsive_content.dart';

Color emojiSurface(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
        ? AppColors.surfaceSecondaryDark
        : AppColors.surfaceSecondaryLight;

Color emojiBorder(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
        ? AppColors.borderNormalDark
        : AppColors.borderNormalLight;

Color emojiMuted(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
        ? AppColors.textSecondaryDark
        : AppColors.iconNeutralLight;

String emojiBytesLabel(int bytes) {
  if (bytes >= 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '$bytes B';
}

class EmojiPageScaffold extends StatelessWidget {
  const EmojiPageScaffold({
    super.key,
    required this.title,
    required this.body,
    this.actions = const [],
    this.bottomNavigationBar,
  });

  final String title;
  final Widget body;
  final List<Widget> actions;
  final Widget? bottomNavigationBar;

  @override
  Widget build(BuildContext context) => Theme(
        data: CampusTheme.withBrandAccent(Theme.of(context)).copyWith(
          visualDensity: VisualDensity.standard,
          materialTapTargetSize: MaterialTapTargetSize.padded,
        ),
        child: Builder(
            builder: (context) => AppPageBackground(builder: (context) => Scaffold(
                  backgroundColor: AppPageBackground.color(context, CampusTheme.pageBackground(context)),
                  appBar: AppPageAppBar(title: Text(title), actions: actions),
                  body: SafeArea(
                      top: false, child: ResponsiveContent.page(child: body)),
                  bottomNavigationBar: bottomNavigationBar == null
                      ? null
                      : Column(mainAxisSize: MainAxisSize.min, children: [
                          ResponsiveContent.page(child: bottomNavigationBar!),
                        ]),
                ))),
      );
}

class EmojiSectionHeader extends StatelessWidget {
  const EmojiSectionHeader(
      {super.key, required this.title, this.detail, this.action});
  final String title;
  final String? detail;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Padding(
        padding:
            const EdgeInsets.only(top: AppSpacing.lg, bottom: AppSpacing.sm),
        child: Row(children: [
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(title,
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontWeight: FontWeight.w600)),
                if (detail != null) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Text(detail!,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: emojiMuted(context),
                        fontFeatures: const [FontFeature.tabularFigures()],
                      )),
                ],
              ])),
          if (action != null) action!,
        ]),
      );
}

class EmojiCover extends StatelessWidget {
  const EmojiCover({super.key, this.image, this.size = 56, this.label});
  final ImageProvider? image;
  final double size;
  final String? label;

  @override
  Widget build(BuildContext context) => Semantics(
        image: image != null,
        label: label,
        child: Container(
          width: size,
          height: size,
          padding: const EdgeInsets.all(AppSpacing.xs),
          decoration: BoxDecoration(
            color: emojiSurface(context),
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(color: emojiBorder(context)),
          ),
          child: image == null
              ? Icon(Icons.collections_outlined, color: emojiMuted(context))
              : Image(
                  image: image!,
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => Icon(
                      Icons.broken_image_outlined,
                      color: emojiMuted(context))),
        ),
      );
}

class EmojiPackRow extends StatelessWidget {
  const EmojiPackRow({
    super.key,
    required this.name,
    required this.detail,
    required this.cover,
    this.status,
    this.statusIcon,
    this.damaged = false,
    this.trailing,
    this.onTap,
  });
  final String name;
  final String detail;
  final Widget cover;
  final String? status;
  final IconData? statusIcon;
  final bool damaged;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadius.md),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
            child: Row(children: [
              cover,
              const SizedBox(width: AppSpacing.md),
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(name,
                        style: Theme.of(context)
                            .textTheme
                            .titleSmall
                            ?.copyWith(fontWeight: FontWeight.w600)),
                    const SizedBox(height: AppSpacing.xs),
                    Text(detail,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: emojiMuted(context),
                          fontFeatures: const [FontFeature.tabularFigures()],
                        )),
                    if (status != null) ...[
                      const SizedBox(height: AppSpacing.xs),
                      Row(children: [
                        if (statusIcon != null) ...[
                          Icon(statusIcon,
                              size: 14,
                              color: damaged
                                  ? Theme.of(context).colorScheme.error
                                  : emojiMuted(context)),
                          const SizedBox(width: AppSpacing.xs),
                        ],
                        Expanded(
                            child: Text(status!,
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(
                                      color: damaged
                                          ? Theme.of(context).colorScheme.error
                                          : emojiMuted(context),
                                    ))),
                      ]),
                    ],
                  ])),
              if (trailing != null) ...[
                const SizedBox(width: AppSpacing.sm),
                trailing!
              ],
            ]),
          ),
        ),
      );
}

class EmojiStateView extends StatelessWidget {
  const EmojiStateView(
      {super.key,
      required this.title,
      this.detail,
      this.icon = Icons.sentiment_satisfied_alt_outlined,
      this.action});
  final String title;
  final String? detail;
  final IconData icon;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg, vertical: AppSpacing.xxl),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, color: emojiMuted(context), size: 32),
          const SizedBox(height: AppSpacing.md),
          Text(title,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleSmall),
          if (detail != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(detail!,
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: emojiMuted(context))),
          ],
          if (action != null) ...[
            const SizedBox(height: AppSpacing.md),
            action!
          ],
        ]),
      );
}

class EmojiInlineError extends StatelessWidget {
  const EmojiInlineError(
      {super.key, required this.message, required this.onRetry});
  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
        child: Row(children: [
          Icon(Icons.info_outline,
              size: 20, color: Theme.of(context).colorScheme.error),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
              child:
                  Text(message, style: Theme.of(context).textTheme.bodySmall)),
          TextButton(
              onPressed: onRetry,
              style: TextButton.styleFrom(minimumSize: const Size(44, 44)),
              child: const Text('重试')),
        ]),
      );
}

class EmojiPreviewItem {
  const EmojiPreviewItem(
      {required this.id,
      required this.name,
      required this.image,
      this.animated = false});
  final String id;
  final String name;
  final ImageProvider image;
  final bool animated;
}

class EmojiPreviewGrid extends StatelessWidget {
  const EmojiPreviewGrid(
      {super.key,
      required this.items,
      this.shrinkWrap = false,
      this.onSelected});
  final List<EmojiPreviewItem> items;
  final bool shrinkWrap;
  final ValueChanged<EmojiPreviewItem>? onSelected;

  @override
  Widget build(BuildContext context) {
    final labelHeight = MediaQuery.textScalerOf(context).scale(12);
    return GridView.builder(
      shrinkWrap: shrinkWrap,
      physics: shrinkWrap ? const NeverScrollableScrollPhysics() : null,
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 132,
        mainAxisExtent: 112 + labelHeight * 2,
        crossAxisSpacing: AppSpacing.sm,
        mainAxisSpacing: AppSpacing.sm,
      ),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        return Semantics(
          button: true,
          label: '${item.name}${item.animated ? '，动图' : ''}，查看大图',
          child: Material(
            color: emojiSurface(context),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadius.md),
                side: BorderSide(color: emojiBorder(context))),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => onSelected == null
                  ? showEmojiPreview(context, item)
                  : onSelected!(item),
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.sm),
                child: Column(children: [
                  Expanded(
                      child: Image(
                          image: item.image,
                          fit: BoxFit.contain,
                          loadingBuilder: (_, child, progress) =>
                              progress == null
                                  ? child
                                  : const Center(
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2)),
                          errorBuilder: (_, __, ___) => Icon(
                              Icons.broken_image_outlined,
                              color: emojiMuted(context)))),
                  const SizedBox(height: AppSpacing.sm),
                  Text(item.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.labelMedium),
                  if (item.animated)
                    Text('动图',
                        style: Theme.of(context)
                            .textTheme
                            .labelSmall
                            ?.copyWith(color: emojiMuted(context))),
                ]),
              ),
            ),
          ),
        );
      },
    );
  }
}

Future<void> showEmojiPreview(BuildContext context, EmojiPreviewItem item,
    {Listenable? session,
    bool Function()? isCurrent,
    List<Widget> actions = const []}) async {
  var attempt = 0;
  StateSetter? invalidatePreview;
  Widget preview(BuildContext context) => isCurrent?.call() == false
      ? const EmojiStateView(title: '账号已切换，请关闭预览')
      : SizedBox(
          width: 320,
          height: MediaQuery.sizeOf(context).height * .36,
          child: Image(
              key: ValueKey(attempt),
              image: item.image,
              fit: BoxFit.contain,
              loadingBuilder: (_, child, progress) => progress == null
                  ? child
                  : const Center(child: CircularProgressIndicator()),
              errorBuilder: (_, __, ___) => EmojiStateView(
                  title: '图片读取失败',
                  icon: Icons.broken_image_outlined,
                  action: TextButton(
                      onPressed: () async {
                        await item.image.evict();
                        if (context.mounted && isCurrent?.call() != false) {
                          invalidatePreview?.call(() => attempt++);
                        }
                      },
                      child: const Text('重试图片')))),
        );
  Widget dialog(BuildContext dialogContext) => AppAlertDialog(
        title: Text(isCurrent?.call() == false ? '预览已结束' : item.name),
        content: preview(dialogContext),
        actions: [
          if (isCurrent?.call() != false) ...actions,
          TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              style: TextButton.styleFrom(minimumSize: const Size(44, 44)),
              child: const Text('关闭'))
        ],
      );
  await showDialog<void>(
      context: context,
      builder: (dialogContext) =>
          StatefulBuilder(builder: (context, setPreviewState) {
            invalidatePreview = setPreviewState;
            return session == null
                ? dialog(context)
                : AnimatedBuilder(
                    animation: session,
                    builder: (context, _) => dialog(context));
          }));
}
