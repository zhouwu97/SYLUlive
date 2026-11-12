import 'package:flutter/material.dart';

import '../../controllers/post_reply_composer_controller.dart';
import '../../theme/app_motion.dart';
import '../../theme/app_radius.dart';
import '../../theme/app_spacing.dart';
import '../app_card.dart';

/// 普通帖子和投票共用评论详情的材质、分区、拖拽及输入避让。
class PostReplyThreadFrame extends StatefulWidget {
  const PostReplyThreadFrame({
    super.key,
    required this.controller,
    required this.parentReply,
    required this.replyCount,
    required this.childrenSliver,
    required this.composer,
  });

  final PostReplyComposerController controller;
  final Widget parentReply;
  final int replyCount;
  final Widget childrenSliver;
  final Widget composer;

  @override
  State<PostReplyThreadFrame> createState() => _PostReplyThreadFrameState();
}

class _PostReplyThreadFrameState extends State<PostReplyThreadFrame> {
  final _sheetController = DraggableScrollableController();
  bool _wasEmoji = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_handleComposerChanges);
  }

  @override
  void didUpdateWidget(PostReplyThreadFrame oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_handleComposerChanges);
      widget.controller.addListener(_handleComposerChanges);
      _wasEmoji = widget.controller.showEmojiPanel;
    }
  }

  void _handleComposerChanges() {
    final isEmoji = widget.controller.showEmojiPanel;
    if (isEmoji &&
        !_wasEmoji &&
        _sheetController.isAttached &&
        _sheetController.size < .90) {
      if (MediaQuery.disableAnimationsOf(context)) {
        _sheetController.jumpTo(.92);
      } else {
        _sheetController.animateTo(.92,
            duration: AppMotion.normal, curve: AppMotion.standard);
      }
    }
    _wasEmoji = isEmoji;
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleComposerChanges);
    _sheetController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final mediaInset = MediaQuery.viewInsetsOf(context).bottom;
        final keyboardInset = widget.controller.keyboardInset > mediaInset
            ? widget.controller.keyboardInset
            : mediaInset;
        return Padding(
          padding: EdgeInsets.only(
              bottom: widget.controller.showEmojiPanel ? 0 : keyboardInset),
          child: DraggableScrollableSheet(
            controller: _sheetController,
            initialChildSize: .72,
            minChildSize: .50,
            maxChildSize: .92,
            expand: false,
            builder: (context, scrollController) => AppCardSurface(
              key: const ValueKey('reply-thread-surface'),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF171B24) : Colors.white,
                borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(AppRadius.lg)),
              ),
              child: Column(
                children: [
                  _header(context, isDark),
                  Expanded(
                    child: CustomScrollView(
                      controller: scrollController,
                      slivers: [
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(AppSpacing.lg,
                                AppSpacing.md, AppSpacing.lg, AppSpacing.lg),
                            child: widget.parentReply,
                          ),
                        ),
                        SliverToBoxAdapter(
                            child: _relatedHeader(context, isDark)),
                        SliverPadding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: AppSpacing.lg),
                          sliver: widget.childrenSliver,
                        ),
                      ],
                    ),
                  ),
                  widget.composer,
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _header(BuildContext context, bool isDark) => Column(
        children: [
          const SizedBox(height: 10),
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: isDark ? Colors.white24 : Colors.grey[300],
              borderRadius: BorderRadius.circular(AppRadius.pill),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            child: Row(
              children: [
                const SizedBox(width: 48),
                Expanded(
                  child: Text('评论详情',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: isDark ? Colors.white : Colors.black87)),
                ),
                IconButton(
                  tooltip: '关闭回复',
                  visualDensity: VisualDensity.standard,
                  constraints:
                      const BoxConstraints(minWidth: 48, minHeight: 48),
                  color: isDark ? Colors.white54 : Colors.grey[600],
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          const AppCardDivider.inset(),
        ],
      );

  Widget _relatedHeader(BuildContext context, bool isDark) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const AppCardDivider.inset(height: AppSpacing.sm),
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.sm),
            child: Row(
              children: [
                Expanded(
                  child: Text('相关回复共 ${widget.replyCount} 条',
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: isDark ? Colors.white60 : Colors.grey[700])),
                ),
                Text('按时间',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: isDark ? Colors.white30 : Colors.grey[400])),
              ],
            ),
          ),
        ],
      );
}
