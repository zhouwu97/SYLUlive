import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../controllers/post_reply_composer_controller.dart';
import '../../models/reply.dart';
import '../../providers/auth_provider.dart';
import '../../theme/app_spacing.dart';
import '../../utils/app_feedback.dart';
import 'post_reply_thread_frame.dart';
import '../post_reply_composer.dart';
import 'post_reply_list.dart';

/// 查看完整讨论并复用详情页的发送逻辑；弹层草稿与页面草稿分别保留。
class PostReplyThreadSheet extends StatefulWidget {
  const PostReplyThreadSheet({
    super.key,
    required this.parentReply,
    required this.initialReplies,
    required this.onSubmit,
    required this.onNeedLogin,
    this.initialTarget,
    this.onAuthorTap,
    this.onMore,
  });

  final Reply parentReply;
  final Reply? initialTarget;
  final List<Reply> initialReplies;
  final Future<Reply?> Function(PostReplyDraft) onSubmit;
  final VoidCallback onNeedLogin;
  final ValueChanged<int>? onAuthorTap;
  final ValueChanged<Reply>? onMore;

  @override
  State<PostReplyThreadSheet> createState() => _PostReplyThreadSheetState();
}

class _PostReplyThreadSheetState extends State<PostReplyThreadSheet> {
  late final AuthProvider _auth;
  late final int? _accountId;
  late final int _accountEpoch;
  final _cancelToken = CancelToken();
  final _composer = PostReplyComposerController();
  late List<Reply> _replies;
  final _createdReplies = <int, Reply>{};
  bool _loading = false;
  bool _loaded = false;
  String? _error;
  String? _nextCursor;
  bool _sending = false;
  late int _total;

  bool get _isCurrentSession =>
      _auth.user?.id == _accountId &&
      _auth.accountSessionEpoch == _accountEpoch;

  @override
  void initState() {
    super.initState();
    _auth = context.read<AuthProvider>();
    _accountId = _auth.user?.id;
    _accountEpoch = _auth.accountSessionEpoch;
    _replies = List.of(widget.initialReplies);
    _total = widget.parentReply.childReplyCount > _replies.length
        ? widget.parentReply.childReplyCount
        : _replies.length;
    final initialTarget = widget.initialTarget ?? widget.parentReply;
    _composer.setReplyTarget(
      parentReplyId: widget.parentReply.id,
      replyToUserId: initialTarget.authorId,
      replyToReplyId: initialTarget.id,
      replyToName: initialTarget.author?.nickname,
    );
    _loadMore();
  }

  @override
  void dispose() {
    _cancelToken.cancel();
    _composer.dispose();
    super.dispose();
  }

  Future<void> _loadMore() async {
    if (_loading || !_isCurrentSession || (_loaded && _nextCursor == null)) {
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final response = await _auth.dio.get(
        '/posts/${widget.parentReply.postId}/replies/${widget.parentReply.id}/children',
        queryParameters: {
          'limit': 50,
          if (_nextCursor != null) 'cursor': _nextCursor,
        },
        cancelToken: _cancelToken,
      );
      if (!mounted || !_isCurrentSession) return;
      final data = response.data;
      if (data is! Map || data['replies'] is! List) {
        throw const FormatException('Invalid reply page');
      }
      final fetched = (data['replies'] as List)
          .map((raw) => Reply.fromJson(Map<String, dynamic>.from(raw as Map)))
          .where((reply) =>
              reply.postId == widget.parentReply.postId &&
              reply.parentReplyId == widget.parentReply.id)
          .toList();
      setState(() {
        // 首次请求从头开始，以真实分页结果替换最多两条的预览。
        final byId = <int, Reply>{
          if (_loaded)
            for (final reply in _replies) reply.id: reply,
          for (final reply in fetched) reply.id: reply,
          ..._createdReplies,
        };
        _replies = byId.values.toList();
        final next = data['next_cursor']?.toString() ?? '';
        _nextCursor = next.isEmpty ? null : next;
        _loaded = true;
      });
    } catch (error) {
      if (!mounted || !_isCurrentSession || _cancelToken.isCancelled) return;
      setState(() {
        _error = error is DioException
            ? AppFeedback.dioErrorMessage(error, fallback: '加载回复失败')
            : '加载回复失败';
        if (error is DioException &&
            [401, 403, 404].contains(error.response?.statusCode)) {
          _replies = [];
          _createdReplies.clear();
        }
      });
    } finally {
      if (mounted && _isCurrentSession) {
        setState(() => _loading = false);
      }
    }
  }

  void _selectReply(Reply reply) {
    if (!_isCurrentSession) return;
    if (reply.isDeleted) {
      AppFeedback.showSnackBar(context, '该评论已删除，无法回复', isError: true);
      return;
    }
    if (!_auth.isLoggedIn) {
      widget.onNeedLogin();
      return;
    }
    _composer.openReply(
      parentReplyId: widget.parentReply.id,
      replyToUserId: reply.authorId,
      replyToReplyId: reply.id,
      replyToName: reply.author?.nickname,
    );
  }

  Future<bool> _sendReply(PostReplyDraft draft) async {
    if (_sending || !_isCurrentSession) return false;
    setState(() => _sending = true);
    try {
      final created = await widget.onSubmit(draft);
      if (!mounted || !_isCurrentSession || created == null) return false;
      setState(() {
        if (!_replies.any((reply) => reply.id == created.id)) {
          _replies.add(created);
          _total++;
        }
        _createdReplies[created.id] = created;
      });
      return true;
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Widget _item(Reply reply) => PostReplyItem(
        reply: reply,
        onReply: () => _selectReply(reply),
        onAuthorTap: widget.onAuthorTap == null
            ? null
            : () => widget.onAuthorTap!(reply.authorId),
        onMore: widget.onMore == null ? null : () => widget.onMore!(reply),
        onLongPress: widget.onMore == null ? null : () => widget.onMore!(reply),
      );

  @override
  Widget build(BuildContext context) {
    context.watch<AuthProvider>();
    final current = _isCurrentSession;
    return PostReplyThreadFrame(
      controller: _composer,
      parentReply:
          current ? _item(widget.parentReply) : const Text('登录状态已变更，请重新打开评论'),
      replyCount: current ? _total : 0,
      childrenSliver: SliverList.list(children: [
        if (current) ...[
          for (final reply in _replies)
            Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.lg),
                child: _item(reply)),
          if (_loading)
            const Center(child: CircularProgressIndicator())
          else if (_error != null) ...[
            Text(_error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
            TextButton(onPressed: _loadMore, child: const Text('重试')),
          ] else if (_nextCursor != null)
            TextButton(onPressed: _loadMore, child: const Text('加载更多回复'))
          else if (_replies.isEmpty)
            const Center(child: Text('暂无回复')),
        ],
      ]),
      composer: current
          ? PostReplyComposer(
              embedded: true,
              controller: _composer,
              sending: _sending,
              enabled: _auth.isLoggedIn,
              preserveReplyTargetOnSuccess: true,
              emojiPanelFallbackHeight: 230,
              emojiPanelMaxHeight: 280,
              onSubmit: _sendReply,
              onNeedLogin: widget.onNeedLogin,
            )
          : const SizedBox.shrink(),
    );
  }
}
