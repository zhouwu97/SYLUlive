import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../controllers/post_reply_composer_controller.dart';
import '../../models/post.dart';
import '../../models/reply.dart';
import '../../providers/auth_provider.dart';
import '../../providers/poll_provider.dart';
import '../../providers/post_provider.dart';
import '../../services/poll_service.dart';
import '../../services/post_reply_service.dart';
import '../../utils/app_feedback.dart';
import '../../widgets/app_action_popup_menu.dart';
import '../../widgets/post_reply/post_reply_list.dart';
import '../../widgets/post_reply_composer.dart';
import '../../widgets/poll/poll_post_card.dart';
import '../../widgets/report_sheet.dart';
import '../user_home_screen.dart';
import 'poll_composer_screen.dart';

class PollDetailScreen extends StatefulWidget {
  final int pollId;
  final Post? initialPost;
  final bool isDesktopSplitMode;
  final bool hideBackButton;
  final ValueChanged<int>? onAuthorTap;

  const PollDetailScreen(
      {super.key,
      required this.pollId,
      this.initialPost,
      this.isDesktopSplitMode = false,
      this.hideBackButton = false,
      this.onAuthorTap});

  @override
  State<PollDetailScreen> createState() => _PollDetailScreenState();
}

class _PollDetailScreenState extends State<PollDetailScreen> {
  Post? _post;
  List<Reply> _replies = [];
  final _replyComposerController = PostReplyComposerController();
  bool _loading = true;
  String? _pollError;
  bool _pollNotFound = false;
  bool _repliesLoading = false;
  String? _repliesError;
  bool _sending = false;
  bool _liked = false;
  int _likeCount = 0;
  late final PollService _service;
  late final PostReplyService _replyService;

  @override
  void initState() {
    super.initState();
    _post = widget.initialPost;
    if (_post != null) {
      _liked = _post!.isLiked;
      _likeCount = _post!.likeCount;
      _loading = false;
    }
    final dio = context.read<AuthProvider>().dio;
    _service = PollService(dio);
    _replyService = PostReplyService(dio);
    _reload();
  }

  @override
  void dispose() {
    _replyComposerController.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final existingPost = _post;
    if (existingPost != null) {
      await Future.wait([
        _loadReplies(existingPost.id),
        _loadPoll(),
      ]);
      return;
    }
    await _loadPoll();
    final loadedPost = _post;
    if (loadedPost != null) await _loadReplies(loadedPost.id);
  }

  Future<void> _loadPoll() async {
    if (mounted) {
      setState(() {
        _pollError = null;
        _pollNotFound = false;
      });
    }
    try {
      final post = await _service.getPoll(widget.pollId);
      if (!mounted) return;
      setState(() {
        _post = post;
        _liked = post.isLiked;
        _likeCount = post.likeCount;
        _loading = false;
        _pollNotFound = false;
      });
      context.read<PollProvider>().applyExternalPostUpdate(post);
      context.read<PostProvider>().applyExternalPostUpdate(post);
    } on PollApiException catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _pollError = error.message;
          _pollNotFound = error.statusCode == 404;
          if (_pollNotFound) _post = null;
        });
      }
    } on DioException catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _pollError = AppFeedback.dioErrorMessage(error, fallback: '加载投票失败');
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _pollError = '加载投票失败';
        });
      }
    }
  }

  Future<void> _loadReplies(int postId) async {
    if (mounted) {
      setState(() {
        _repliesLoading = true;
        _repliesError = null;
      });
    }
    try {
      final response =
          await context.read<AuthProvider>().dio.get('/posts/$postId/replies');
      if (!mounted) return;
      // 分页重构后响应为 {replies, total, next_cursor} 对象。
      final data = response.data;
      final raw = data is Map ? data['replies'] : data;
      final replies = (raw is List ? raw : const [])
          .map((e) => Reply.fromJson(e as Map<String, dynamic>))
          .toList();
      setState(() {
        _replies = replies;
        _repliesLoading = false;
      });
    } on DioException catch (error) {
      if (mounted) {
        setState(() {
          _repliesLoading = false;
          _repliesError =
              AppFeedback.dioErrorMessage(error, fallback: '加载评论失败');
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _repliesLoading = false;
          _repliesError = '加载评论失败';
        });
      }
    }
  }

  Future<bool> _sendReply(PostReplyDraft draft) async {
    if (draft.isEmpty ||
        _sending ||
        _post == null ||
        !context.read<AuthProvider>().isLoggedIn) {
      return false;
    }
    setState(() => _sending = true);
    try {
      final reply = await _replyService.submit(_post!.id, draft);
      if (!mounted) return false;
      setState(() {
        _replies.insert(0, reply);
        _post = _post!.copyWith(replyCount: _post!.replyCount + 1);
      });
      context.read<PostProvider>().applyExternalPostUpdate(_post!);
      context.read<PollProvider>().applyExternalPostUpdate(_post!);
      return true;
    } on DioException catch (error) {
      if (mounted) {
        AppFeedback.showSnackBar(
          context,
          AppFeedback.dioErrorMessage(error, fallback: '评论失败'),
          isError: true,
        );
      }
      return false;
    } catch (_) {
      if (mounted) {
        AppFeedback.showSnackBar(context, '评论失败', isError: true);
      }
      return false;
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _toggleLike() async {
    if (!context.read<AuthProvider>().isLoggedIn || _post == null) return;
    final next = !_liked;
    setState(() {
      _liked = next;
      _likeCount += next ? 1 : -1;
    });
    try {
      if (next) {
        await context.read<AuthProvider>().dio.post('/posts/${_post!.id}/like');
      } else {
        await context
            .read<AuthProvider>()
            .dio
            .delete('/posts/${_post!.id}/like');
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _liked = !next;
          _likeCount += next ? -1 : 1;
        });
      }
    }
    if (mounted) {
      _post = _post!.copyWith(isLiked: _liked, likeCount: _likeCount);
      context.read<PostProvider>().applyExternalPostUpdate(_post!);
      context.read<PollProvider>().applyExternalPostUpdate(_post!);
    }
  }

  void _openLogin() {
    Navigator.of(context).pushNamed('/login');
  }

  void _openReply(Reply reply) {
    if (!context.read<AuthProvider>().isLoggedIn) {
      _openLogin();
      return;
    }
    _replyComposerController.openReply(
      parentReplyId: reply.id,
      replyToUserId: reply.authorId,
      replyToName: reply.author?.nickname,
    );
  }

  Future<void> _togglePin() async {
    final post = _post;
    if (post == null) return;
    final provider = context.read<PostProvider>();
    final result = post.isActivePinned
        ? await provider.unpinPost(post.id)
        : await provider.pinPost(
            postId: post.id,
            pinnedUntil: DateTime.now().add(const Duration(days: 7)),
            reason: '管理员置顶校园投票',
          );
    if (!mounted) return;
    if (result.success && result.post != null) {
      setState(() => _post = result.post);
      context.read<PollProvider>().applyExternalPostUpdate(result.post!);
      AppFeedback.showSnackBar(
        context,
        post.isActivePinned ? '已取消置顶' : '已置顶到首页',
      );
      return;
    }
    AppFeedback.showSnackBar(
      context,
      result.errorMessage ?? '操作失败',
      isError: true,
    );
  }

  Future<void> _applyFeatured() async {
    final post = _post;
    if (post == null) return;
    try {
      await context.read<AuthProvider>().dio.post(
        '/posts/${post.id}/featured-applications',
        data: {'reason': '校园投票内容申请精华'},
      );
      if (mounted) AppFeedback.showSnackBar(context, '精华申请已提交');
    } on DioException catch (error) {
      if (mounted) {
        AppFeedback.showSnackBar(
          context,
          AppFeedback.dioErrorMessage(error, fallback: '提交申请失败'),
          isError: true,
        );
      }
    }
  }

  Future<void> _unfeature() async {
    final post = _post;
    if (post == null) return;
    try {
      await context
          .read<AuthProvider>()
          .dio
          .post('/admin/posts/${post.id}/unfeature');
      if (!mounted) return;
      AppFeedback.showSnackBar(context, '已取消首页精华');
      await _loadPoll();
    } on DioException catch (error) {
      if (mounted) {
        AppFeedback.showSnackBar(
          context,
          AppFeedback.dioErrorMessage(error, fallback: '操作失败'),
          isError: true,
        );
      }
    }
  }

  Widget _buildMoreMenu(Post post) {
    final poll = post.pollMeta!;
    final isAdmin = context.watch<AuthProvider>().user?.isAdmin ?? false;
    final entries = <Object>[
      if (isAdmin)
        AppPopupAction(
          value: 'pin',
          label: post.isActivePinned ? '取消首页置顶' : '置顶到首页',
          icon: post.isActivePinned
              ? Icons.vertical_align_top_outlined
              : Icons.push_pin_outlined,
        ),
      if (isAdmin && post.isFeatured)
        const AppPopupAction(
          value: 'unfeature',
          label: '取消首页精华',
          icon: Icons.star_border_rounded,
        ),
      if (poll.isOwner && !post.isFeatured)
        const AppPopupAction(
          value: 'apply_featured',
          label: '申请精华',
          icon: Icons.star_outline_rounded,
        ),
      if (poll.isOwner)
        const AppPopupAction(
          value: 'edit',
          label: '编辑投票',
          icon: Icons.edit_outlined,
        ),
      if (poll.isOwner && poll.isActive)
        const AppPopupAction(
          value: 'close',
          label: '提前结束',
          icon: Icons.stop_circle_outlined,
        ),
      if (poll.isOwner || isAdmin)
        const AppPopupAction(
          value: 'delete',
          label: '删除投票',
          icon: Icons.delete_outline_rounded,
          danger: true,
        ),
      if (!poll.isOwner && !isAdmin)
        const AppPopupAction(
          value: 'report',
          label: '举报投票',
          icon: Icons.flag_outlined,
        ),
    ];
    return AppActionPopupMenu(
      icon: const Icon(Icons.more_horiz_rounded),
      entries: entries,
      onSelected: (value) {
        switch (value) {
          case 'pin':
            _togglePin();
            break;
          case 'unfeature':
            _unfeature();
            break;
          case 'apply_featured':
            _applyFeatured();
            break;
          case 'edit':
            _edit();
            break;
          case 'close':
            _close();
            break;
          case 'delete':
            _delete();
            break;
          case 'report':
            showReportSheet(
              context,
              targetId: post.id,
              targetType: 'post',
            );
            break;
        }
      },
    );
  }

  Future<void> _edit() async {
    if (_post == null) return;
    final result = await Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => PollComposerScreen(editingPost: _post)));
    if (result is Post && mounted) {
      setState(() {
        _post = result;
        _liked = result.isLiked;
        _likeCount = result.likeCount;
      });
      context.read<PostProvider>().applyExternalPostUpdate(result);
      context.read<PollProvider>().applyExternalPostUpdate(result);
    }
  }

  Future<void> _close() async {
    if (_post?.pollMeta == null) return;
    final pollId = _post!.pollMeta!.id;
    final provider = context.read<PollProvider>();
    final updated = await provider.closePoll(pollId);
    if (!mounted) return;
    if (updated != null) {
      setState(() => _post = updated);
    } else {
      AppFeedback.error(
        provider.mutationError(pollId) ?? '提前结束投票失败',
        context: context,
      );
    }
  }

  Future<void> _delete() async {
    if (_post == null) return;
    final yes = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
                    title: const Text('删除投票？'),
                    content: const Text('删除后不可恢复。'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('取消')),
                      FilledButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('删除'))
                    ])) ??
        false;
    if (!yes || !mounted) return;

    final provider = context.read<PollProvider>();
    final deleted = await provider.deletePoll(widget.pollId);

    if (!mounted) return;
    if (deleted) {
      Navigator.pop(context, true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final post = _post;
    if (_loading && post == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (post == null) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_pollNotFound ? '投票不存在或已删除' : (_pollError ?? '加载投票失败')),
              if (!_pollNotFound) ...[
                const SizedBox(height: 12),
                FilledButton.icon(
                    onPressed: _loadPoll,
                    icon: const Icon(Icons.refresh),
                    label: const Text('重试')),
              ],
            ],
          ),
        ),
      );
    }
    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: widget.hideBackButton
          ? null
          : AppBar(
              title: const Text('投票详情'),
              actions: [_buildMoreMenu(post)],
            ),
      body: Column(
        children: [
          Expanded(
            child: RefreshIndicator(
              onRefresh: _reload,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
                children: [
                  if (_pollError != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        _pollError!,
                        style: const TextStyle(color: Colors.red),
                      ),
                    ),
                  const Text(
                    '非官方用户投票，结果仅代表参与用户的选择。',
                    style: TextStyle(fontSize: 12, color: Colors.black54),
                  ),
                  const SizedBox(height: 8),
                  PollPostCard(
                    post: post,
                    variant: PollCardVariant.centerFull,
                    onPostUpdated: (updated) {
                      setState(() {
                        _post = updated;
                        _liked = updated.isLiked;
                        _likeCount = updated.likeCount;
                      });
                    },
                    onAuthorTap: widget.onAuthorTap ??
                        (id) => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => UserHomeScreen(userId: id),
                              ),
                            ),
                  ),
                  const Divider(height: 24),
                  Text(
                    '评论 ${post.replyCount}',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (_repliesLoading)
                    const Center(
                      child: Padding(
                        padding: EdgeInsets.all(16),
                        child: CircularProgressIndicator(),
                      ),
                    )
                  else if (_repliesError != null)
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            _repliesError!,
                            style: const TextStyle(color: Colors.red),
                          ),
                        ),
                        TextButton(
                          onPressed: () => _loadReplies(post.id),
                          child: const Text('重试'),
                        ),
                      ],
                    ),
                  if (!_repliesLoading && _repliesError == null)
                    PostReplyList(
                      replies: _replies,
                      onReply: _openReply,
                      onAuthorTap: widget.onAuthorTap ??
                          (id) => Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => UserHomeScreen(userId: id),
                                ),
                              ),
                      onMore: (reply) => showReportSheet(
                        context,
                        targetId: reply.id,
                        targetType: 'reply',
                      ),
                      onLongPress: (reply) => showReportSheet(
                        context,
                        targetId: reply.id,
                        targetType: 'reply',
                      ),
                    ),
                ],
              ),
            ),
          ),
          PostReplyComposer(
            controller: _replyComposerController,
            replyCount: post.replyCount,
            likeCount: _likeCount,
            liked: _liked,
            sending: _sending,
            enabled: context.watch<AuthProvider>().isLoggedIn,
            onToggleLike: _toggleLike,
            onSubmit: _sendReply,
            onNeedLogin: _openLogin,
          ),
        ],
      ),
    );
  }
}
