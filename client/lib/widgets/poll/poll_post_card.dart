import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../config/api_constants.dart';
import '../../models/poll.dart';
import '../../models/post.dart';
import '../../providers/auth_provider.dart';
import '../../providers/poll_provider.dart';
import '../../utils/app_feedback.dart';
import '../cached_avatar.dart';
import '../feed/feed_post_action_menu.dart';
import '../post_media/post_media_view.dart';
import 'poll_option_tile.dart';

enum PollCardVariant { homeCompact, centerFull, profileCompact }

class PollPostCard extends StatefulWidget {
  final Post post;
  final VoidCallback? onTap;
  final ValueChanged<int>? onAuthorTap;
  final ValueChanged<Post>? onPostUpdated;
  final PollCardVariant variant;

  /// 卡片右上角操作菜单回调（FEED-3）。为空时不渲染菜单。
  final ValueChanged<FeedPostAction>? onPostAction;
  final bool allowNotInterested;
  final bool allowHideAuthor;
  final bool allowReport;

  const PollPostCard({
    super.key,
    required this.post,
    this.onTap,
    this.onAuthorTap,
    this.onPostUpdated,
    this.onPostAction,
    this.allowNotInterested = true,
    this.allowHideAuthor = true,
    this.allowReport = true,
    this.variant = PollCardVariant.homeCompact,
  });

  @override
  State<PollPostCard> createState() => _PollPostCardState();
}

class _PollPostCardState extends State<PollPostCard> {
  Set<int> _selected = {};

  @override
  void initState() {
    super.initState();
    _syncSelection();
  }

  @override
  void didUpdateWidget(covariant PollPostCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.post.pollMeta != widget.post.pollMeta) _syncSelection();
  }

  void _syncSelection() {
    _selected = widget.post.pollMeta?.chosenOptionIds.toSet() ?? {};
  }

  /// 当前登录用户是否是本帖作者（仅当渲染操作菜单时调用）。
  bool _isMine(BuildContext context) {
    final user = context.read<AuthProvider>().user;
    return user != null && widget.post.authorId == user.id;
  }

  void _toggle(int id) {
    final poll = widget.post.pollMeta!;
    if (!poll.canVote || !poll.isActive) return;
    setState(() {
      if (poll.isMultiple) {
        if (_selected.contains(id)) {
          _selected.remove(id);
        } else if (_selected.length < poll.maxChoices) {
          _selected.add(id);
        } else {
          AppFeedback.info('最多选择 ${poll.maxChoices} 项', context: context);
        }
      } else {
        _selected = {id};
      }
    });
  }

  Future<void> _submit() async {
    if (_selected.isEmpty) return;
    final poll = widget.post.pollMeta!;
    final result = await context
        .read<PollProvider>()
        .submitBallot(poll.id, _selected.toList());
    if (!mounted) return;
    if (result != null) {
      widget.onPostUpdated?.call(result);
    } else {
      final message = context.read<PollProvider>().mutationError(poll.id);
      if (message != null) {
        AppFeedback.error(message, context: context);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final poll = widget.post.pollMeta!;
    final provider = context.watch<PollProvider>();
    final isMutating = provider.isMutating(poll.id);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final options = widget.variant == PollCardVariant.centerFull
        ? poll.options
        : poll.options.take(3).toList();
    final chosen = poll.chosenOptionIds.toSet();
    final hasChanges = !_sameSet(_selected, chosen);
    final canSubmit = poll.canVote && _selected.isNotEmpty && hasChanges;
    final authorName = widget.post.author?.nickname ?? '匿名用户';

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      elevation: 0,
      color: isDark ? const Color(0xFF171A22) : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
            color: isDark ? Colors.white12 : const Color(0xFFECECF1)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: widget.onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  InkWell(
                    onTap: widget.onAuthorTap == null
                        ? null
                        : () => widget.onAuthorTap!(widget.post.authorId),
                    customBorder: const CircleBorder(),
                    child: CachedAvatar(
                      radius: 17,
                      imageUrl: widget.post.author?.avatar.isNotEmpty == true
                          ? ApiConstants.fullUrl(widget.post.author!.avatar)
                          : null,
                      fallbackText: authorName,
                    ),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(authorName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 13, fontWeight: FontWeight.w600)),
                        Text(
                          _relativeTime(widget.post.createdAt),
                          style: TextStyle(
                              fontSize: 11.5,
                              color: Theme.of(context).hintColor),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFF7C3AED).withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Text('校园投票',
                        style: TextStyle(
                            color: Color(0xFF7C3AED),
                            fontSize: 11,
                            fontWeight: FontWeight.w700)),
                  ),
                  if (widget.onPostAction != null) ...[
                    const SizedBox(width: 4),
                    FeedPostActionMenu(
                      isMine: _isMine(context),
                      isDark: isDark,
                      onAction: widget.onPostAction!,
                      allowNotInterested: widget.allowNotInterested,
                      allowHideAuthor: widget.allowHideAuthor,
                      allowReport: widget.allowReport,
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 12),
              Text(widget.post.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w700, height: 1.3)),
              if (widget.post.content.trim().isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(widget.post.content,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 13,
                        height: 1.35,
                        color: isDark ? Colors.white70 : Colors.black54)),
              ],
              if (widget.post.images.any(
                (image) => image.resolvedOriginUrl.isNotEmpty,
              )) ...[
                const SizedBox(height: 10),
                PostMediaView(
                  images: widget.post.images,
                  variant: widget.variant == PollCardVariant.centerFull
                      ? PostMediaVariant.detail
                      : PostMediaVariant.feed,
                ),
              ],
              const SizedBox(height: 10),
              Text(
                poll.isMultiple
                    ? '多选 · 最多选 ${poll.maxChoices} 项'
                    : '单选 · 选择 1 项',
                style: const TextStyle(
                    color: Color(0xFF7C3AED),
                    fontSize: 12,
                    fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 7),
              ...options.map((option) => Padding(
                    padding: const EdgeInsets.only(bottom: 7),
                    child: PollOptionTile(
                      option: option,
                      selected: _selected.contains(option.id),
                      multiple: poll.isMultiple,
                      enabled: poll.canVote && !isMutating,
                      showResult: poll.resultsVisible,
                      onTap: () => _toggle(option.id),
                    ),
                  )),
              if (poll.options.length > options.length)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                      '还有 ${poll.options.length - options.length} 个选项，进入详情查看',
                      style: TextStyle(
                          fontSize: 12, color: Theme.of(context).hintColor)),
                ),
              if (!poll.resultsVisible)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF7C3AED).withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(_visibilityHint(poll),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF6D28D9),
                      )),
                ),
              const SizedBox(height: 3),
              SizedBox(
                width: double.infinity,
                height: 42,
                child: FilledButton(
                  onPressed: canSubmit && !isMutating ? _submit : null,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF16A34A),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(7)),
                  ),
                  child: isMutating
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : Text(_actionLabel(poll, _selected, hasChanges)),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Text('${poll.participantCount} 人参与',
                      style: TextStyle(
                          fontSize: 12, color: Theme.of(context).hintColor)),
                  const Spacer(),
                  Icon(Icons.schedule,
                      size: 15, color: Theme.of(context).hintColor),
                  const SizedBox(width: 3),
                  Text(_remainingText(poll.remainingSeconds, poll.isClosed),
                      style: TextStyle(
                          fontSize: 12, color: Theme.of(context).hintColor)),
                  if (widget.variant != PollCardVariant.centerFull) ...[
                    const SizedBox(width: 12),
                    Icon(
                      Icons.chat_bubble_outline,
                      size: 15,
                      color: Theme.of(context).hintColor,
                    ),
                    const SizedBox(width: 3),
                    Text(
                      '${widget.post.replyCount}',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).hintColor,
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  bool _sameSet(Set<int> a, Set<int> b) =>
      a.length == b.length && a.containsAll(b);

  String _actionLabel(PollMeta poll, Set<int> selected, bool hasChanges) {
    if (!poll.isActive) {
      return poll.resultsVisible ? '查看投票结果' : '投票已结束';
    }
    if (poll.hasVoted && !poll.canChange) return '已提交，不可修改';
    if (poll.hasVoted && !hasChanges) return '已提交选择';
    if (selected.isEmpty) return poll.isMultiple ? '选择后提交' : '选择一项后投票';
    return poll.hasVoted ? '确认修改' : '提交选择';
  }

  String _visibilityHint(PollMeta poll) {
    switch (poll.resultsVisibility) {
      case 'after_end':
        return poll.isClosed ? '投票已结束，结果即将公开' : '结果将在投票结束后公开';
      case 'private':
        return poll.hasVoted ? '已参与 · 结果仅创建者可见' : '结果仅创建者可见';
      case 'after_vote':
        return poll.hasVoted ? '已参与' : '投票后可查看结果';
      default:
        return '结果将在满足公开条件后显示';
    }
  }

  String _relativeTime(DateTime value) {
    final difference = DateTime.now().difference(value.toLocal());
    if (difference.inMinutes < 1) return '刚刚';
    if (difference.inHours < 1) return '${difference.inMinutes}分钟前';
    if (difference.inDays < 1) return '${difference.inHours}小时前';
    return '${difference.inDays}天前';
  }

  String _remainingText(int seconds, bool closed) {
    if (closed || seconds <= 0) return '已结束';
    final duration = Duration(seconds: seconds);
    if (duration.inDays > 0) return '还剩${duration.inDays}天';
    if (duration.inHours > 0) return '还剩${duration.inHours}小时';
    return '还剩${duration.inMinutes}分钟';
  }
}
