import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:dio/dio.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../config/api_constants.dart';
import '../models/post.dart';
import '../models/reply.dart';
import '../models/user.dart';
import '../providers/post_provider.dart';
import '../utils/app_feedback.dart';
import '../utils/post_image_cache.dart';
import '../widgets/report_sheet.dart';
import '../widgets/cached_avatar.dart';
import 'create_post_screen.dart';
import 'image_viewer_screen.dart';

import 'user_home_screen.dart';

class PostDetailScreen extends StatefulWidget {
  final int postId;
  final bool isMarket;
  final Post? initialPost;
  final int? targetReplyId;
  final bool isDesktopSplitMode;
  final bool hideBackButton;
  final ValueChanged<int>? onAuthorTap;

  const PostDetailScreen({
    super.key,
    required this.postId,
    this.isMarket = false,
    this.initialPost,
    this.targetReplyId,
    this.isDesktopSplitMode = false,
    this.hideBackButton = false,
    this.onAuthorTap,
  });

  @override
  State<PostDetailScreen> createState() => _PostDetailScreenState();
}

class _PinPostDialogResult {
  final DateTime until;
  final int weight;
  final String reason;

  const _PinPostDialogResult({
    required this.until,
    required this.weight,
    required this.reason,
  });
}

class _PinPostDialog extends StatefulWidget {
  final bool isSuperAdmin;

  const _PinPostDialog({required this.isSuperAdmin});

  @override
  State<_PinPostDialog> createState() => _PinPostDialogState();
}

class _PinPostDialogState extends State<_PinPostDialog> {
  final _reasonController = TextEditingController();
  int _days = 3;
  double _weight = 50;

  @override
  void dispose() {
    _reasonController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dayOptions = <int>[1, 3, 7];
    if (widget.isSuperAdmin) {
      dayOptions.add(30);
    }

    return AlertDialog(
      title: const Text('置顶到首页'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DropdownButtonFormField<int>(
              initialValue: _days,
              decoration: const InputDecoration(labelText: '置顶时长'),
              items: dayOptions
                  .map(
                    (days) => DropdownMenuItem(
                      value: days,
                      child: Text('$days 天'),
                    ),
                  )
                  .toList(),
              onChanged: (value) {
                if (value == null) return;
                setState(() => _days = value);
              },
            ),
            const SizedBox(height: 18),
            Text('权重：${_weight.round()}'),
            Slider(
              value: _weight,
              min: 0,
              max: 100,
              divisions: 20,
              label: _weight.round().toString(),
              onChanged: (value) => setState(() => _weight = value),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _reasonController,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: '置顶理由',
                hintText: '可选，默认显示为管理员置顶',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.pop(
              context,
              _PinPostDialogResult(
                until: DateTime.now().add(Duration(days: _days)),
                weight: _weight.round(),
                reason: _reasonController.text.trim(),
              ),
            );
          },
          child: const Text('置顶'),
        ),
      ],
    );
  }
}

class _PostDetailScreenState extends State<PostDetailScreen> {
  late Dio _dio;
  Post? _post;
  List<Reply> _replies = [];
  bool _isLoading = true;
  String? _errorMessage;
  bool _liked = false;
  int _likeCount = 0;
  final _replyController = TextEditingController();
  final _replyFocus = FocusNode();
  bool _isReplyComposerOpen = false;
  int _marketImageIndex = 0;
  int? _parentReplyId;
  String? _replyToName;
  int? _replyToUserId;
  bool _isSending = false;
  final Set<int> _expandedThreads = {};
  bool _hasPendingFeaturedApp = false;

  final Map<int, GlobalKey> _replyKeys = {};
  bool _hasScrolledToTarget = false;
  int? _highlightedReplyId;
  Timer? _highlightTimer;

  @override
  void initState() {
    super.initState();
    _dio = context.read<AuthProvider>().dio;
    if (widget.initialPost != null) {
      _post = widget.initialPost;
      _isLoading = false;
    }
    _loadPost();
  }

  @override
  void dispose() {
    _replyController.dispose();
    _replyFocus.dispose();
    _highlightTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadPost() async {
    if (mounted)
      setState(() {
        _isLoading = true;
        _errorMessage = null;
      });
    try {
      final response = await _dio.get('/posts/${widget.postId}');
      final repliesResponse = await _dio.get('/posts/${widget.postId}/replies');

      try {
        final statusResponse = await _dio
            .get('/posts/${widget.postId}/featured-application-status');
        if (mounted) {
          setState(() {
            _hasPendingFeaturedApp = statusResponse.data['has_pending'] == true;
          });
        }
      } catch (e) {
        // ignore status check failure
      }

      final fetchedPost = Post.fromJson(response.data);
      final fallbackPost = widget.initialPost;
      final mergedPost = fallbackPost != null &&
              fallbackPost.images.length > fetchedPost.images.length
          ? fetchedPost.copyWith(images: fallbackPost.images)
          : fetchedPost;
      if (mounted)
        setState(() {
          _replies = (repliesResponse.data as List)
              .map((e) => Reply.fromJson(e))
              .toList();
          _post = mergedPost.copyWith(replyCount: _replies.length);
          _liked = mergedPost.isLiked;
          _likeCount = mergedPost.likeCount;
          _isLoading = false;
        });
      // 同步到外部列表以更新浏览量等数据
      if (mounted) {
        context.read<PostProvider>().updatePostInCache(_post!);
      }
      if (widget.targetReplyId != null && !_hasScrolledToTarget) {
        _prepareTargetReplyAndScroll();
      }
    } on DioException catch (e) {
      final msg = AppFeedback.dioErrorMessage(e, fallback: '加载帖子失败');
      if (mounted)
        setState(() {
          _isLoading = false;
          _errorMessage = msg;
        });
    } catch (e) {
      if (mounted)
        setState(() {
          _isLoading = false;
          _errorMessage = '加载失败: $e';
        });
    }
  }

  void _prepareTargetReplyAndScroll() {
    if (widget.targetReplyId == null) return;

    // 寻找目标回复
    final targetReply =
        _replies.where((r) => r.id == widget.targetReplyId).firstOrNull;
    if (targetReply == null) return;

    // 如果目标是子回复，强制展开它的父级楼中楼
    if (targetReply.parentReplyId != null) {
      _expandedThreads.add(targetReply.parentReplyId!);
    }

    setState(() {}); // 触发重新渲染，确保子组件挂载

    _scheduleScrollToTarget(widget.targetReplyId!, 3);
  }

  void _scheduleScrollToTarget(int targetId, int retries) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      final key = _replyKeys[targetId];
      final context = key?.currentContext;

      if (context != null) {
        Scrollable.ensureVisible(
          context,
          duration: const Duration(milliseconds: 500),
          curve: Curves.easeInOut,
          alignment: 0.5,
        );
        setState(() {
          _hasScrolledToTarget = true;
          _highlightedReplyId = targetId;
        });

        _highlightTimer?.cancel();
        _highlightTimer = Timer(const Duration(seconds: 3), () {
          if (mounted) {
            setState(() {
              _highlightedReplyId = null;
            });
          }
        });
      } else if (retries > 0) {
        // 重试机制，防止第一帧还没算完布局
        Future.delayed(const Duration(milliseconds: 100), () {
          if (mounted) _scheduleScrollToTarget(targetId, retries - 1);
        });
      } else {
        _hasScrolledToTarget = true;
        debugPrint('目标回复未进入组件树: $targetId');
        return;
      }
    });
  }

  Future<void> _toggleLike() async {
    if (!context.read<AuthProvider>().isLoggedIn) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请先登录')));
      return;
    }
    if (mounted)
      setState(() {
        _liked = !_liked;
        _likeCount += _liked ? 1 : -1;
        if (_post != null) {
          _post = _post!.copyWith(isLiked: _liked, likeCount: _likeCount);
        }
      });
    if (_post != null) {
      context.read<PostProvider>().updatePostInCache(_post!);
    }

    try {
      if (_liked) {
        await _dio.post('/posts/${widget.postId}/like');
      } else {
        await _dio.delete('/posts/${widget.postId}/like');
      }
    } catch (_) {
      if (mounted)
        setState(() {
          _liked = !_liked;
          _likeCount += _liked ? 1 : -1;
          if (_post != null) {
            _post = _post!.copyWith(isLiked: _liked, likeCount: _likeCount);
          }
        });
      if (_post != null) {
        context.read<PostProvider>().updatePostInCache(_post!);
      }
    }
  }

  Future<void> _sendReply() async {
    if (_isSending) return;
    final content = _replyController.text.trim();
    if (content.isEmpty) return;

    if (mounted) setState(() => _isSending = true);

    // 先保存 parentReplyId，后面 setState 会清空它
    final parentId = _parentReplyId;
    final replyToUserId = _replyToUserId;

    // 乐观更新：立即在本地插入评论
    final user = context.read<AuthProvider>().user;
    if (user != null && _post != null) {
      final tempId = -DateTime.now().millisecondsSinceEpoch;
      final tempReply = Reply(
        id: tempId,
        postId: widget.postId,
        authorId: user.id,
        content: content,
        createdAt: DateTime.now(),
        author: User(
          id: user.id,
          studentId: user.studentId,
          nickname: user.nickname,
          avatar: user.avatar,
          createdAt: DateTime.now(),
        ),
        parentReplyId: parentId,
      );
      _replies.insert(0, tempReply);
      _post = _post!.copyWith(replyCount: _post!.replyCount + 1);
      context.read<PostProvider>().updatePostInCache(_post!);
    }
    _replyController.clear();
    _replyFocus.unfocus();
    if (mounted)
      setState(() {
        _isReplyComposerOpen = false;
        _parentReplyId = null;
        _replyToName = null;
        _replyToUserId = null;
      });

    // 后台静默发送
    try {
      final formData = FormData.fromMap({
        'content': content,
        if (parentId != null) 'parent_reply_id': parentId.toString(),
        if (replyToUserId != null) 'reply_to_user_id': replyToUserId.toString(),
      });
      await _dio.post('/posts/${widget.postId}/replies', data: formData);
      // 静默刷新获取真实 ID
      final repliesResponse = await _dio.get('/posts/${widget.postId}/replies');
      if (mounted && repliesResponse.data is List) {
        setState(() {
          _replies = (repliesResponse.data as List)
              .map((r) => Reply.fromJson(r))
              .toList();
        });
      }
    } on DioException catch (e) {
      if (mounted) {
        setState(() {
          _replies.removeWhere((r) => r.id < 0);
          if (_post != null) {
            _post = _post!.copyWith(replyCount: _post!.replyCount - 1);
          }
        });
        if (_post != null) {
          context.read<PostProvider>().updatePostInCache(_post!);
        }
        AppFeedback.showSnackBar(
          context,
          AppFeedback.dioErrorMessage(e, fallback: '发送失败'),
          isError: true,
        );
      }
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  Future<void> _deletePost() async {
    final post = _post;
    if (post == null) return;
    final postProvider = context.read<PostProvider>();

    final confirmed = await AppFeedback.confirmDanger(
      context,
      title: '删除帖子',
      message: '确定要删除这条帖子吗？删除后普通用户不可见，此操作不可撤销。',
    );
    if (!confirmed) return;

    final result = await postProvider.deletePostDetailed(post.id);
    if (!mounted) return;
    if (result.success) {
      AppFeedback.showSnackBar(context, '帖子已删除');
      Navigator.pop(context, true);
    } else {
      AppFeedback.showSnackBar(
        context,
        result.errorMessage ?? '删除帖子失败',
        isError: true,
      );
    }
  }

  Future<void> _editPost() async {
    final post = _post;
    if (post == null) return;
    final updated = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => CreatePostScreen(
          boardId: post.boardId,
          defaultPostType: post.postType,
          editingPost: post,
        ),
      ),
    );
    if (updated == true && mounted) {
      await _loadPost();
    }
  }

  Future<void> _unfeaturePost() async {
    final post = _post;
    if (post == null) return;
    final confirmed = await AppFeedback.confirmDanger(
      context,
      title: '取消精华',
      message: '确定取消该帖精华吗？取消后将从精华列表移除。',
    );
    if (!confirmed) return;
    try {
      await _dio.post('/admin/posts/${post.id}/unfeature');
      if (mounted) {
        AppFeedback.showSnackBar(context, '已取消精华');
        _loadPost(); // 刷新状态
      }
    } catch (e) {
      if (mounted) {
        AppFeedback.showSnackBar(context, '操作失败', isError: true);
      }
    }
  }

  Future<void> _pinPost() async {
    final post = _post;
    if (post == null) return;

    final isSuperAdmin =
        context.read<AuthProvider>().user?.isSuperAdmin ?? false;
    final dialogResult = await showDialog<_PinPostDialogResult>(
      context: context,
      builder: (_) => _PinPostDialog(isSuperAdmin: isSuperAdmin),
    );
    if (dialogResult == null) return;

    final postProvider = context.read<PostProvider>();
    final result = await postProvider.pinPost(
      postId: post.id,
      pinnedUntil: dialogResult.until,
      pinnedWeight: dialogResult.weight,
      reason: dialogResult.reason,
    );
    if (!mounted) return;

    if (result.success) {
      final updated = result.post;
      if (updated != null) {
        setState(() => _post = updated);
      }
      await postProvider.refreshHomePinnedFeeds(
        refreshFeatured: updated?.isFeatured == true,
      );
      if (!mounted) return;
      AppFeedback.showSnackBar(context, '已置顶到首页');
    } else {
      AppFeedback.showSnackBar(
        context,
        result.errorMessage ?? '置顶失败',
        isError: true,
      );
    }
  }

  Future<void> _unpinPost() async {
    final post = _post;
    if (post == null) return;

    final confirmed = await AppFeedback.confirmDanger(
      context,
      title: '取消置顶',
      message: '确定取消这条帖子的首页置顶吗？',
      confirmText: '取消置顶',
    );
    if (!confirmed) return;

    final postProvider = context.read<PostProvider>();
    final result = await postProvider.unpinPost(post.id);
    if (!mounted) return;

    if (result.success) {
      final updated = result.post ??
          post.copyWith(
            isPinned: false,
            pinnedBy: 0,
            pinnedWeight: 0,
            pinnedReason: '',
            clearPinnedAt: true,
            clearPinnedUntil: true,
          );
      setState(() => _post = updated);
      await postProvider.refreshHomePinnedFeeds(
        refreshFeatured: updated.isFeatured,
      );
      if (!mounted) return;
      AppFeedback.showSnackBar(context, '已取消置顶');
    } else {
      AppFeedback.showSnackBar(
        context,
        result.errorMessage ?? '取消置顶失败',
        isError: true,
      );
    }
  }

  Future<String?> _askReason({
    required String title,
    required String hint,
  }) async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          minLines: 3,
          maxLines: 6,
          decoration: InputDecoration(hintText: hint),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('提交'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result == null || result.trim().isEmpty) return null;
    return result.trim();
  }

  Future<void> _applyFeatured() async {
    if (!context.read<AuthProvider>().isLoggedIn) {
      AppFeedback.showSnackBar(context, '请先登录', isError: true);
      return;
    }
    final reason = await _askReason(
      title: '申请精华',
      hint: '说明这篇帖子为什么值得成为精华。恶意或低质量申请可能被管理员扣诚信分。',
    );
    if (reason == null) return;
    try {
      await _dio.post(
        '/posts/${widget.postId}/featured-applications',
        data: {'reason': reason},
      );
      if (!mounted) return;
      setState(() {
        _hasPendingFeaturedApp = true;
      });
      AppFeedback.showSnackBar(context, '精华申请已提交');
    } on DioException catch (e) {
      if (!mounted) return;
      AppFeedback.showSnackBar(
        context,
        AppFeedback.dioErrorMessage(e, fallback: '提交失败'),
        isError: true,
      );
    }
  }

  Future<void> _applyCollaboration() async {
    if (!context.read<AuthProvider>().isLoggedIn) {
      AppFeedback.showSnackBar(context, '请先登录', isError: true);
      return;
    }
    final reason = await _askReason(
      title: '申请共同创作',
      hint: '说明你想补充或改进哪些内容。',
    );
    if (reason == null) return;
    try {
      await _dio.post(
        '/posts/${widget.postId}/collaboration-applications',
        data: {'reason': reason},
      );
      if (!mounted) return;
      AppFeedback.showSnackBar(context, '共同创作申请已提交');
    } on DioException catch (e) {
      if (!mounted) return;
      AppFeedback.showSnackBar(
        context,
        AppFeedback.dioErrorMessage(e, fallback: '提交失败'),
        isError: true,
      );
    }
  }

  Future<void> _openCreationManagement() async {
    final data = await Future.wait([
      _dio.get('/user/collaboration-applications/received'),
      _dio.get('/user/revision-proposals/received'),
    ]);
    if (!mounted) return;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        final applications = (data[0].data as List?) ?? [];
        final revisions = (data[1].data as List?) ?? [];
        return SafeArea(
          child: DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.85,
            minChildSize: 0.45,
            maxChildSize: 0.95,
            builder: (_, controller) => ListView(
              controller: controller,
              padding: const EdgeInsets.all(16),
              children: [
                const Text(
                  '创作管理',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 14),
                const Text('共同创作申请',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                if (applications.isEmpty)
                  const Text('暂无共同创作申请')
                else
                  ...applications.map((item) => _buildCollabApplicationTile(
                        Map<String, dynamic>.from(item as Map),
                      )),
                const SizedBox(height: 18),
                const Text('修改版本审核',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                if (revisions.isEmpty)
                  const Text('暂无修改版本')
                else
                  ...revisions.map((item) => _buildRevisionProposalTile(
                        Map<String, dynamic>.from(item as Map),
                      )),
              ],
            ),
          ),
        );
      },
    );
    if (mounted) _loadPost();
  }

  Future<void> _submitRevisionProposal() async {
    final post = _post;
    if (post == null) return;
    final titleController = TextEditingController(text: post.title);
    final contentController = TextEditingController(text: post.content);
    final summaryController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('提交修改版本'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: titleController,
                  decoration: const InputDecoration(labelText: '标题'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: contentController,
                  minLines: 8,
                  maxLines: 14,
                  decoration: const InputDecoration(labelText: '正文'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: summaryController,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(labelText: '修改说明'),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('提交'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      titleController.dispose();
      contentController.dispose();
      summaryController.dispose();
      return;
    }
    try {
      await _dio.post('/posts/${post.id}/revision-proposals', data: {
        'title': titleController.text.trim(),
        'content': contentController.text.trim(),
        'change_summary': summaryController.text.trim(),
      });
      if (!mounted) return;
      AppFeedback.showSnackBar(context, '修改版本已提交给原作者');
    } on DioException catch (e) {
      if (!mounted) return;
      AppFeedback.showSnackBar(
        context,
        AppFeedback.dioErrorMessage(e, fallback: '提交失败'),
        isError: true,
      );
    } finally {
      titleController.dispose();
      contentController.dispose();
      summaryController.dispose();
    }
  }

  Widget _buildCollabApplicationTile(Map<String, dynamic> item) {
    final applicant = item['applicant'] as Map?;
    final status = item['status']?.toString() ?? '';
    return Card(
      child: ListTile(
        title: Text(applicant?['nickname']?.toString() ?? '申请人'),
        subtitle: Text('${item['reason'] ?? ''}\n状态：$status'),
        isThreeLine: true,
        trailing: status == 'pending'
            ? Wrap(
                spacing: 6,
                children: [
                  TextButton(
                    onPressed: () => _reviewCollab(item['id'], false),
                    child: const Text('拒绝'),
                  ),
                  FilledButton(
                    onPressed: () => _reviewCollab(item['id'], true),
                    child: const Text('同意'),
                  ),
                ],
              )
            : null,
      ),
    );
  }

  Widget _buildRevisionProposalTile(Map<String, dynamic> item) {
    final proposer = item['proposer'] as Map?;
    final status = item['status']?.toString() ?? '';
    return Card(
      child: ListTile(
        title: Text(item['proposed_title']?.toString().isNotEmpty == true
            ? item['proposed_title'].toString()
            : '修改版本'),
        subtitle: Text(
          '${proposer?['nickname'] ?? '提交者'}：${item['change_summary'] ?? ''}\n状态：$status',
        ),
        isThreeLine: true,
        trailing: status == 'pending'
            ? Wrap(
                spacing: 6,
                children: [
                  TextButton(
                    onPressed: () => _reviewRevision(item['id'], false),
                    child: const Text('驳回'),
                  ),
                  FilledButton(
                    onPressed: () => _reviewRevision(item['id'], true),
                    child: const Text('发布'),
                  ),
                ],
              )
            : null,
      ),
    );
  }

  Future<void> _reviewCollab(dynamic id, bool approve) async {
    await _dio.post(
      '/collaboration-applications/$id/${approve ? 'approve' : 'reject'}',
      data: {'reply': approve ? '同意共同创作' : '暂不接受'},
    );
    if (!mounted) return;
    AppFeedback.showSnackBar(context, approve ? '已同意' : '已拒绝');
    Navigator.pop(context);
    _openCreationManagement();
  }

  Future<void> _reviewRevision(dynamic id, bool approve) async {
    try {
      await _dio.post(
        '/revision-proposals/$id/${approve ? 'approve' : 'reject'}',
        data: {'reply': approve ? '发布修改版本' : '暂不发布'},
      );
      if (!mounted) return;
      AppFeedback.showSnackBar(context, approve ? '已发布' : '已驳回');
      Navigator.pop(context);
      _openCreationManagement();
    } on DioException catch (e) {
      if (!mounted) return;
      AppFeedback.showSnackBar(
        context,
        AppFeedback.dioErrorMessage(e, fallback: '处理失败'),
        isError: true,
      );
    }
  }

  Future<void> _resolveMarketPost() async {
    final post = _post;
    if (post == null) return;
    final actionLabel = _marketCompleteLabel(post.postType);
    final postProvider = context.read<PostProvider>();
    final confirmed = await AppFeedback.confirmDanger(
      context,
      title: actionLabel,
      message: '确认后会直接删除这条帖子，避免继续占用集市列表。此操作不可撤销。',
    );
    if (!confirmed) return;
    final result = await postProvider.deletePostDetailed(post.id);
    if (!mounted) return;
    if (result.success) {
      AppFeedback.showSnackBar(context, '$actionLabel，帖子已移除');
      Navigator.pop(context, true);
    } else {
      AppFeedback.showSnackBar(
        context,
        result.errorMessage ?? '$actionLabel失败',
        isError: true,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final currentUser = context.watch<AuthProvider>().user;
    final canDelete = _post != null &&
        currentUser != null &&
        (currentUser.id == _post!.authorId || currentUser.isAdmin);
    final canEdit = _isCurrentUserPostOwner();
    final isOwn = _isCurrentUserPostOwner();
    final isAdmin = currentUser?.isAdmin ?? false;
    final overlayStyle = (!isDark && !widget.isMarket
            ? SystemUiOverlayStyle.dark
            : SystemUiOverlayStyle.light)
        .copyWith(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: Colors.transparent,
    );

    // 桌面分栏模式：保持透明背景
    final bool transparentMode =
        widget.isDesktopSplitMode && widget.hideBackButton;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: overlayStyle,
      child: Scaffold(
        backgroundColor: transparentMode
            ? Colors.transparent
            : (isDark ? const Color(0xFF131720) : const Color(0xFFF6F7F9)),
        appBar: transparentMode
            ? AppBar(
                backgroundColor: Colors.transparent,
                elevation: 0,
                automaticallyImplyLeading: false,
              )
            : _buildWaterAppBar(isDark,
                canEdit: canEdit,
                canDelete: canDelete,
                isOwn: isOwn,
                isAdmin: isAdmin),
        body: Stack(
          children: [
            if (_isLoading)
              const SafeArea(
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_errorMessage != null)
              SafeArea(child: _buildErrorView(isDark))
            else if (_post == null)
              SafeArea(child: _buildEmptyView(isDark))
            else if (widget.isMarket)
              _buildMarketDetail(isDark)
            else
              Column(
                children: [
                  Expanded(child: _buildWaterDetail(isDark)),
                  _buildWaterReplyBar(isDark),
                ],
              ),
          ],
        ),
      ),
    );
  }

  /// 水帖专用 AppBar：不透明背景 + 居中标题 + 更多菜单
  PreferredSizeWidget _buildWaterAppBar(
    bool isDark, {
    required bool canEdit,
    required bool canDelete,
    required bool isOwn,
    required bool isAdmin,
  }) {
    return AppBar(
      backgroundColor: isDark ? const Color(0xFF131720) : Colors.white,
      elevation: 0.5,
      automaticallyImplyLeading: !widget.hideBackButton,
      leading: widget.hideBackButton ? null : const BackButton(),
      title: const Text(
        '帖子详情',
        style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
      ),
      centerTitle: true,
      actions: [
        if (_post != null)
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_horiz),
            onSelected: (value) {
              switch (value) {
                case 'edit':
                  _editPost();
                  break;
                case 'delete':
                  _deletePost();
                  break;
                case 'pin':
                  _pinPost();
                  break;
                case 'unpin':
                  _unpinPost();
                  break;
                case 'report':
                  showReportSheet(
                    context,
                    targetId: widget.postId,
                    targetType: 'post',
                  );
                  break;
                case 'unfeature':
                  _unfeaturePost();
                  break;
              }
            },
            itemBuilder: (context) {
              final items = <PopupMenuEntry<String>>[];
              if (isAdmin && _post?.boardId == 1) {
                items.add(PopupMenuItem(
                  value: _post!.isActivePinned ? 'unpin' : 'pin',
                  child: Text(_post!.isActivePinned ? '取消置顶' : '置顶到首页'),
                ));
              }
              // 自己的帖子：编辑 + 删除（不举报自己）
              if (isOwn) {
                items.add(const PopupMenuItem(
                  value: 'edit',
                  child: Text('编辑帖子'),
                ));
                items.add(const PopupMenuItem(
                  value: 'delete',
                  child: Text('删除帖子', style: TextStyle(color: Colors.red)),
                ));
              } else if (isAdmin) {
                // 管理员看他人帖子：删除 + 举报
                items.add(const PopupMenuItem(
                  value: 'delete',
                  child: Text('删除帖子', style: TextStyle(color: Colors.red)),
                ));
                items.add(const PopupMenuItem(
                  value: 'report',
                  child: Text('举报帖子'),
                ));
                if (_post?.isFeatured == true) {
                  items.add(const PopupMenuItem(
                    value: 'unfeature',
                    child: Text('取消精华'),
                  ));
                }
              } else {
                // 普通用户看他人帖子：仅举报
                items.add(const PopupMenuItem(
                  value: 'report',
                  child: Text('举报帖子'),
                ));
              }
              return items;
            },
          ),
      ],
    );
  }

  // ---- 错误 / 空 ----

  Widget _buildErrorView(bool isDark) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Container(
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF171B24) : Colors.white,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.cloud_off,
                size: 48,
                color: isDark ? Colors.white30 : Colors.grey[400],
              ),
              const SizedBox(height: 14),
              Text(
                _errorMessage!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: isDark ? Colors.white60 : Colors.grey[600],
                  fontSize: 15,
                ),
              ),
              const SizedBox(height: 18),
              OutlinedButton.icon(
                onPressed: _loadPost,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('重试'),
                style: OutlinedButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyView(bool isDark) {
    return Center(
      child: Text(
        '帖子不存在',
        style: TextStyle(
          color: isDark ? Colors.white54 : Colors.grey[500],
          fontSize: 15,
        ),
      ),
    );
  }

  // ---- 集市布局（完全保留不变） ----

  Widget _buildMarketDetail(bool isDark) {
    final p = _post!;
    if (widget.isDesktopSplitMode) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 左侧文本与评论区
          Expanded(
            flex: 5,
            child: Column(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(24, 24, 24, 80),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (p.title.isNotEmpty) ...[
                          Text(
                            p.title,
                            style: TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                              color: isDark ? Colors.white : Colors.black87,
                            ),
                          ),
                          const SizedBox(height: 12),
                        ],
                        if (p.price > 0) ...[
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              const Text(
                                '¥ ',
                                style: TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFFFF6B6B),
                                ),
                              ),
                              Text(
                                p.price.toStringAsFixed(
                                  p.price.truncateToDouble() == p.price ? 0 : 2,
                                ),
                                style: const TextStyle(
                                  fontSize: 32,
                                  fontWeight: FontWeight.w900,
                                  color: Color(0xFFFF6B6B),
                                  height: 1.0,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                        ],
                        Text(
                          p.content,
                          style: TextStyle(
                            fontSize: 16,
                            height: 1.6,
                            color: isDark ? Colors.white70 : Colors.black87,
                          ),
                        ),
                        const SizedBox(height: 24),
                        _buildAuthorCard(p, isDark),
                        if (p.contact.isNotEmpty) ...[
                          const SizedBox(height: 24),
                          GestureDetector(
                            onTap: () {
                              Clipboard.setData(ClipboardData(text: p.contact));
                              AppFeedback.showSnackBar(context, '联系方式已复制到剪贴板');
                            },
                            child: _buildContactChip(p.contact, isDark),
                          ),
                        ],
                        if (_canUseOwnerMarketActions()) ...[
                          const SizedBox(height: 24),
                          _buildOwnerMarketActions(isDark),
                        ],
                        const SizedBox(height: 32),
                        _buildActionBar(isDark),
                        const SizedBox(height: 24),
                        _buildCommentsHeader(isDark),
                        const SizedBox(height: 10),
                        _buildCompactReplies(isDark),
                      ],
                    ),
                  ),
                ),
                _buildReplyBar(isDark),
              ],
            ),
          ),
          // 右侧图片区域
          Container(
            width: 1,
            color:
                isDark ? Colors.white10 : Colors.black.withValues(alpha: 0.05),
          ),
          Expanded(
            flex: 4,
            child: p.images.isNotEmpty
                ? _buildMarketHeroImage(p, isDark, forceFitHeight: true)
                : Container(
                    color: isDark
                        ? const Color(0xFF131720)
                        : const Color(0xFFF4F6FB),
                    child: Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.image_not_supported_outlined,
                            size: 64,
                            color: isDark ? Colors.white24 : Colors.grey[300],
                          ),
                          const SizedBox(height: 16),
                          Text(
                            '没有图片展示',
                            style: TextStyle(
                              color: isDark ? Colors.white38 : Colors.grey[500],
                              fontSize: 16,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
          ),
        ],
      );
    }

    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.only(bottom: 80),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (p.images.isNotEmpty)
                  _buildMarketHeroImage(p, isDark)
                else
                  SizedBox(
                    height: MediaQuery.of(context).padding.top + kToolbarHeight,
                  ),
                Transform.translate(
                  offset: Offset(0, p.images.isNotEmpty ? -24 : 0),
                  child: Container(
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF131720) : Colors.white,
                      borderRadius: BorderRadius.vertical(
                        top: Radius.circular(p.images.isNotEmpty ? 24 : 0),
                      ),
                    ),
                    padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (p.title.isNotEmpty) ...[
                          Text(
                            p.title,
                            style: TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                              color: isDark ? Colors.white : Colors.black87,
                            ),
                          ),
                          const SizedBox(height: 12),
                        ],
                        if (p.price > 0) ...[
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              const Text(
                                '¥ ',
                                style: TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFFFF6B6B),
                                ),
                              ),
                              Text(
                                p.price.toStringAsFixed(
                                  p.price.truncateToDouble() == p.price ? 0 : 2,
                                ),
                                style: const TextStyle(
                                  fontSize: 32,
                                  fontWeight: FontWeight.w900,
                                  color: Color(0xFFFF6B6B),
                                  height: 1.0,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                        ],
                        Text(
                          p.content,
                          style: TextStyle(
                            fontSize: 16,
                            height: 1.6,
                            color: isDark ? Colors.white70 : Colors.black87,
                          ),
                        ),
                        const SizedBox(height: 24),
                        _buildAuthorCard(p, isDark),
                        if (p.contact.isNotEmpty) ...[
                          const SizedBox(height: 24),
                          GestureDetector(
                            onTap: () {
                              Clipboard.setData(ClipboardData(text: p.contact));
                              AppFeedback.showSnackBar(context, '联系方式已复制到剪贴板');
                            },
                            child: _buildContactChip(p.contact, isDark),
                          ),
                        ],
                        if (_canUseOwnerMarketActions()) ...[
                          const SizedBox(height: 24),
                          _buildOwnerMarketActions(isDark),
                        ],
                        const SizedBox(height: 32),
                        _buildActionBar(isDark),
                        const SizedBox(height: 24),
                        _buildCommentsHeader(isDark),
                        const SizedBox(height: 10),
                        _buildCompactReplies(isDark),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        _buildReplyBar(isDark),
      ],
    );
  }

  Widget _buildMarketHeroImage(
    Post p,
    bool isDark, {
    bool forceFitHeight = false,
  }) {
    final urls = _resolvedImageUrls(p);
    if (urls.isEmpty) return const SizedBox.shrink();
    return Stack(
      children: [
        Container(
          width: double.infinity,
          height: forceFitHeight ? double.infinity : 400,
          color: isDark
              ? Colors.white.withValues(alpha: 0.06)
              : Colors.black.withValues(alpha: 0.04),
          child: PageView.builder(
            itemCount: urls.length,
            onPageChanged: (index) => setState(() => _marketImageIndex = index),
            itemBuilder: (_, index) => GestureDetector(
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) =>
                      ImageViewerScreen(imageUrls: urls, initialIndex: index),
                ),
              ),
              child: CachedNetworkImage(
                cacheManager: PostImageCache.manager,
                imageUrl: urls[index],
                width: double.infinity,
                fit: forceFitHeight ? BoxFit.contain : BoxFit.cover,
                placeholder: (_, __) => Container(
                  color: isDark ? Colors.white10 : Colors.grey[200],
                ),
                errorWidget: (_, __, ___) => Container(
                  color: isDark ? Colors.white10 : Colors.grey[200],
                  child: const Icon(
                    Icons.broken_image,
                    size: 40,
                    color: Colors.grey,
                  ),
                ),
              ),
            ),
          ),
        ),
        if (urls.length > 1)
          Positioned(
            bottom: 40,
            right: 16,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Text(
                '${_marketImageIndex + 1}/${urls.length}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
      ],
    );
  }

  // ===================================================================
  // 水帖详情布局（全新重构）
  // ===================================================================

  Widget _buildWaterDetail(bool isDark) {
    final p = _post!;
    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        children: [
          // 白色内容卡片：作者 + 标题 + 正文 + 图片 + 信息 + 操作栏
          Container(
            color: isDark ? const Color(0xFF131720) : Colors.white,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 12),
                _buildWaterAuthorHeader(p, isDark),
                if (p.title.isNotEmpty || p.content.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  _buildWaterPostBody(p, isDark),
                  _buildFeaturedCollaborationActions(p, isDark),
                ],
                if (p.images.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  _buildAdaptiveWaterImages(p, isDark),
                ],
                const SizedBox(height: 12),
                _buildWaterActionBar(isDark),
              ],
            ),
          ),
          // 8px 分区
          Container(
            height: 8,
            color: isDark ? const Color(0xFF1A1E28) : const Color(0xFFF0F0F0),
          ),
          // 白色评论区卡片
          Container(
            color: isDark ? const Color(0xFF131720) : Colors.white,
            child: _buildWaterCommentsSection(isDark),
          ),
          // 底部留白给固定输入栏
          const SizedBox(height: 60),
        ],
      ),
    );
  }

  // ---- 水帖作者头部（紧凑，无灰色背景） ----

  Widget _buildWaterAuthorHeader(Post p, bool isDark) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        if (p.author != null) _openAuthorHome(p.author!.id);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            // 头像
            GestureDetector(
              onTap: () {
                if (p.author?.avatar.isNotEmpty == true) {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ImageViewerScreen(
                        imageUrls: [ApiConstants.fullUrl(p.author!.avatar)],
                      ),
                    ),
                  );
                }
              },
              child: CachedAvatar(
                radius: 22,
                imageUrl: p.author?.avatar.isNotEmpty == true
                    ? ApiConstants.fullUrl(p.author!.avatar)
                    : null,
                fallbackText: p.author?.nickname,
              ),
            ),
            const SizedBox(width: 12),
            // 信息
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 第一行：昵称 + 等级
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          p.author?.nickname ?? '匿名',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 15,
                            color: isDark ? Colors.white : Colors.black87,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (p.author != null) ...[
                        const SizedBox(width: 6),
                        _buildLevelBadge(p.author!, isDark),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  // 第二行：诚信分 + 发布时间
                  Row(
                    children: [
                      _buildCreditBadge(p.author?.creditScore ?? 100),
                      const SizedBox(width: 8),
                      Text(
                        _formatTime(p.createdAt),
                        style: TextStyle(
                          fontSize: 11,
                          color: isDark ? Colors.white30 : Colors.grey[400],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCreditBadge(int score) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: _creditColor(score).withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        '诚信 $score%',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: _creditColor(score),
        ),
      ),
    );
  }

  // ---- 水帖正文（无额外内边距） ----

  Widget _buildWaterPostBody(Post p, bool isDark) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (p.title.isNotEmpty) ...[
            Text(
              p.title,
              style: TextStyle(
                fontSize: 21,
                fontWeight: FontWeight.w700,
                height: 1.35,
                color: isDark ? Colors.white : Colors.black87,
              ),
            ),
            const SizedBox(height: 10),
          ],
          if (p.content.isNotEmpty)
            SelectionContainer.disabled(
              child: Text(
                p.content,
                style: TextStyle(
                  fontSize: 16,
                  height: 1.65,
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.82)
                      : const Color(0xFF333333),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildFeaturedCollaborationActions(Post p, bool isDark) {
    final user = context.watch<AuthProvider>().user;
    if (user == null || widget.isMarket) return const SizedBox.shrink();

    final isOwner = user.id == p.authorId;
    final actions = <Widget>[];
    if (!p.isFeatured) {
      if (_hasPendingFeaturedApp) {
        actions.add(
          const OutlinedButton(
            onPressed: null,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.hourglass_empty, size: 18),
                SizedBox(width: 8),
                Text('精华申请待审核'),
              ],
            ),
          ),
        );
      } else {
        actions.add(
          OutlinedButton.icon(
            onPressed: _applyFeatured,
            icon: const Icon(Icons.workspace_premium_outlined, size: 18),
            label: const Text('申请精华'),
          ),
        );
      }
    } else if (!isOwner) {
      actions.add(
        OutlinedButton.icon(
          onPressed: _applyCollaboration,
          icon: const Icon(Icons.edit_note_rounded, size: 18),
          label: const Text('申请共同创作'),
        ),
      );
      actions.add(
        FilledButton.icon(
          onPressed: _submitRevisionProposal,
          icon: const Icon(Icons.publish_outlined, size: 18),
          label: const Text('提交修改版本'),
        ),
      );
    } else {
      actions.add(
        FilledButton.icon(
          onPressed: _openCreationManagement,
          icon: const Icon(Icons.manage_accounts_outlined, size: 18),
          label: const Text('创作管理'),
        ),
      );
    }

    if (actions.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
      child: Wrap(spacing: 10, runSpacing: 8, children: [
        if (p.isFeatured)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: const Color(0xFFFFB020).withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.workspace_premium_rounded,
                    size: 16, color: Color(0xFFD97706)),
                SizedBox(width: 5),
                Text(
                  '精华',
                  style: TextStyle(
                    color: Color(0xFFD97706),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ...actions,
      ]),
    );
  }

  // ---- 自适应图片布局 ----

  Widget _buildAdaptiveWaterImages(Post p, bool isDark) {
    final urls = _resolvedImageUrls(p).take(9).toList(growable: false);
    if (urls.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: switch (urls.length) {
        1 => _buildSingleWaterImage(urls.first, isDark),
        2 => _buildTwoWaterImages(urls, isDark),
        _ => _buildMultiWaterImageGrid(urls, isDark),
      },
    );
  }

  /// 单张图：按图片原比例展示，不额外生成虚化或裁切背景。
  Widget _buildSingleWaterImage(String url, bool isDark) {
    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ImageViewerScreen(
            imageUrls: [url],
            initialIndex: 0,
          ),
        ),
      ),
      child: SizedBox(
        width: double.infinity,
        child: Center(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 420),
              child: CachedNetworkImage(
                cacheManager: PostImageCache.manager,
                imageUrl: url,
                fit: BoxFit.contain,
                placeholder: (_, __) => const SizedBox.shrink(),
                errorWidget: (_, __, ___) => Container(
                  height: 300,
                  color: isDark ? Colors.white10 : Colors.grey[200],
                  child: const Icon(Icons.broken_image,
                      size: 40, color: Colors.grey),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 两张图：左右并排的等宽方格。
  Widget _buildTwoWaterImages(List<String> urls, bool isDark) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: Row(
        children: List.generate(urls.length, (index) {
          final url = urls[index];
          return Expanded(
            child: GestureDetector(
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ImageViewerScreen(
                    imageUrls: urls,
                    initialIndex: index,
                  ),
                ),
              ),
              child: Container(
                margin: EdgeInsets.only(
                  right: index == 0 ? 2 : 0,
                  left: index == 1 ? 2 : 0,
                ),
                child: AspectRatio(
                  aspectRatio: 1,
                  child: CachedNetworkImage(
                    cacheManager: PostImageCache.manager,
                    imageUrl: url,
                    fit: BoxFit.cover,
                    placeholder: (_, __) => Container(
                      color: isDark ? Colors.white10 : Colors.grey[200],
                    ),
                    errorWidget: (_, __, ___) => Container(
                      color: isDark ? Colors.white10 : Colors.grey[200],
                      child: const Icon(Icons.broken_image,
                          size: 32, color: Colors.grey),
                    ),
                  ),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }

  /// 三张及以上普通帖子图片：最多 9 张，统一按 3 列方格展示。
  Widget _buildMultiWaterImageGrid(List<String> urls, bool isDark) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          mainAxisSpacing: 4,
          crossAxisSpacing: 4,
          childAspectRatio: 1,
        ),
        itemCount: urls.length,
        itemBuilder: (context, index) {
          return GestureDetector(
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) =>
                    ImageViewerScreen(imageUrls: urls, initialIndex: index),
              ),
            ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                CachedNetworkImage(
                  cacheManager: PostImageCache.manager,
                  imageUrl: urls[index],
                  fit: BoxFit.cover,
                  placeholder: (_, __) => Container(
                    color: isDark ? Colors.white10 : Colors.grey[200],
                  ),
                  errorWidget: (_, __, ___) => Container(
                    color: isDark ? Colors.white10 : Colors.grey[200],
                    child: const Icon(Icons.broken_image,
                        size: 24, color: Colors.grey),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  // ---- 水帖操作栏 ----

  Widget _buildWaterActionBar(bool isDark) {
    return Container(
      height: 48,
      margin: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(
            color: isDark ? Colors.white10 : const Color(0xFFEEEEEE),
          ),
          bottom: BorderSide(
            color: isDark ? Colors.white10 : const Color(0xFFEEEEEE),
          ),
        ),
      ),
      child: Row(
        children: [
          // 点赞
          GestureDetector(
            onTap: _toggleLike,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _liked ? Icons.thumb_up : Icons.thumb_up_outlined,
                  size: 18,
                  color: _liked
                      ? Theme.of(context).primaryColor
                      : (isDark ? Colors.white38 : Colors.grey[500]),
                ),
                const SizedBox(width: 4),
                Text(
                  '$_likeCount',
                  style: TextStyle(
                    fontSize: 13,
                    color: _liked
                        ? Theme.of(context).primaryColor
                        : (isDark ? Colors.white38 : Colors.grey[500]),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 28),
          // 评论
          GestureDetector(
            onTap: () => _openReplyComposer(),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.chat_bubble_outline,
                  size: 18,
                  color: isDark ? Colors.white38 : Colors.grey[500],
                ),
                const SizedBox(width: 4),
                Text(
                  '评论 ${_post?.replyCount ?? 0}',
                  style: TextStyle(
                    fontSize: 13,
                    color: isDark ? Colors.white38 : Colors.grey[500],
                  ),
                ),
              ],
            ),
          ),
          const Spacer(),
          // 浏览量
          Icon(
            Icons.visibility_outlined,
            size: 16,
            color: isDark ? Colors.white24 : Colors.grey[400],
          ),
          const SizedBox(width: 3),
          Text(
            '浏览 ${_post?.viewCount ?? 0}',
            style: TextStyle(
              fontSize: 12,
              color: isDark ? Colors.white24 : Colors.grey[400],
            ),
          ),
        ],
      ),
    );
  }

  // ---- 水帖评论区 ----

  Widget _buildWaterCommentsSection(bool isDark) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 评论标题
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Text(
            '评论 ${_post?.replyCount ?? _replies.length}',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: isDark ? Colors.white : Colors.black87,
            ),
          ),
        ),
        const SizedBox(height: 10),
        // 评论列表
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: _buildFullReplies(isDark),
        ),
      ],
    );
  }

  // ---- 水帖底部回复栏 ----

  Widget _buildWaterReplyBar(bool isDark) {
    if (_isReplyComposerOpen) {
      // 展开的输入框
      return Container(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF131720) : const Color(0xFFF6F7F9),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 12,
              offset: const Offset(0, -3),
            ),
          ],
        ),
        child: SafeArea(
          child: Container(
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF1E1E32) : Colors.white,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: isDark
                    ? Colors.white.withValues(alpha: 0.08)
                    : const Color(0xFFE5E7EB),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
              child: Row(
                children: [
                  // 关闭按钮
                  GestureDetector(
                    onTap: () {
                      _replyController.clear();
                      _replyFocus.unfocus();
                      if (mounted)
                        setState(() {
                          _isReplyComposerOpen = false;
                          _parentReplyId = null;
                          _replyToName = null;
                          _replyToUserId = null;
                        });
                    },
                    child: Container(
                      width: 36,
                      height: 36,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: isDark
                            ? Colors.white10
                            : Colors.black.withValues(alpha: 0.05),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        Icons.close,
                        size: 18,
                        color: isDark ? Colors.white54 : Colors.grey[700],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _replyController,
                      focusNode: _replyFocus,
                      decoration: InputDecoration(
                        hintText: _replyToName != null
                            ? '回复 @$_replyToName...'
                            : '写下你的想法...',
                        hintStyle: TextStyle(
                          color: isDark ? Colors.white30 : Colors.grey[400],
                          fontSize: 14,
                        ),
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                      ),
                      style: TextStyle(
                        fontSize: 14,
                        color: isDark ? Colors.white : Colors.black87,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  // 发送按钮
                  GestureDetector(
                    onTap: _isSending ? null : _sendReply,
                    child: Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        gradient: _isSending
                            ? const LinearGradient(
                                colors: [Color(0xFF9CA3AF), Color(0xFF9CA3AF)],
                              )
                            : const LinearGradient(
                                colors: [Color(0xFF667EEA), Color(0xFF764BA2)],
                              ),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: _isSending
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(
                              Icons.send_rounded,
                              color: Colors.white,
                              size: 20,
                            ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    // 折叠状态：说点什么… 入口
    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF131720) : Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 8,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: GestureDetector(
            onTap: () => _openReplyComposer(),
            child: Container(
              height: 44,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: isDark
                    ? Colors.white.withValues(alpha: 0.06)
                    : const Color(0xFFF5F5F5),
                borderRadius: BorderRadius.circular(22),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.edit_outlined,
                    size: 16,
                    color: isDark ? Colors.white38 : Colors.grey[400],
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '说点什么…',
                    style: TextStyle(
                      fontSize: 14,
                      color: isDark ? Colors.white38 : Colors.grey[500],
                    ),
                  ),
                  const Spacer(),
                  Container(
                    width: 32,
                    height: 28,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      color: isDark
                          ? Colors.white.withValues(alpha: 0.08)
                          : const Color(0xFFE8E8E8),
                    ),
                    child: Icon(
                      Icons.send_rounded,
                      size: 14,
                      color: isDark ? Colors.white30 : Colors.grey[400],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ---- 作者卡片（集市复用，保持不变） ----

  Widget _buildAuthorCard(Post p, bool isDark) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        if (p.author != null) {
          _openAuthorHome(p.author!.id);
        }
      },
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: isDark ? const Color(0x99171B24) : const Color(0x0A000000),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Row(
          children: [
            GestureDetector(
              onTap: () {
                if (p.author?.avatar.isNotEmpty == true) {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ImageViewerScreen(
                        imageUrls: [ApiConstants.fullUrl(p.author!.avatar)],
                      ),
                    ),
                  );
                }
              },
              child: CachedAvatar(
                radius: 24,
                imageUrl: p.author?.avatar.isNotEmpty == true
                    ? ApiConstants.fullUrl(p.author!.avatar)
                    : null,
                fallbackText: p.author?.nickname,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          p.author?.nickname ?? '匿名',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 16,
                            color: isDark ? Colors.white : Colors.black87,
                          ),
                        ),
                      ),
                      if (p.author != null) ...[
                        const SizedBox(width: 6),
                        _buildLevelBadge(p.author!, isDark),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: _creditColor(
                            p.author?.creditScore ?? 100,
                          ).withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          '诚信 ${p.author?.creditScore ?? 100}%',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: _creditColor(p.author?.creditScore ?? 100),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Icon(
                        Icons.visibility_outlined,
                        size: 13,
                        color: isDark ? Colors.white30 : Colors.grey[400],
                      ),
                      const SizedBox(width: 3),
                      Text(
                        '${p.viewCount}',
                        style: TextStyle(
                          fontSize: 11,
                          color: isDark ? Colors.white30 : Colors.grey[400],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Text(
              _formatTime(p.createdAt),
              style: TextStyle(
                fontSize: 12,
                color: isDark ? Colors.white30 : Colors.grey[400],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _openAuthorHome(int userId) {
    final handler = widget.onAuthorTap;
    if (handler != null) {
      handler(userId);
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => UserHomeScreen(userId: userId)),
    );
  }

  // ---- 操作栏（集市复用，保持不变） ----

  Widget _buildActionBar(bool isDark) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceAround,
      children: [
        _buildActionButton(
          icon: _liked ? Icons.thumb_up : Icons.thumb_up_outlined,
          color: _liked
              ? const Color(0xFFFF6B6B)
              : (isDark ? Colors.white38 : Colors.grey.shade500),
          label: '$_likeCount',
          onTap: _toggleLike,
        ),
        _buildActionButton(
          icon: Icons.chat_bubble_outline,
          color: isDark ? Colors.white38 : Colors.grey.shade500,
          label: '${_replies.length}',
          onTap: _openReplyComposer,
        ),
        IconButton(
          icon: Icon(
            Icons.report_outlined,
            color: isDark ? Colors.white30 : Colors.grey[400],
            size: 20,
          ),
          onPressed: () => showReportSheet(
            context,
            targetId: widget.postId,
            targetType: 'post',
          ),
          tooltip: '举报',
        ),
      ],
    );
  }

  Widget _buildOwnerMarketActions(bool isDark) {
    final post = _post!;
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _editPost,
            icon: const Icon(Icons.edit_outlined, size: 18),
            label: const Text('编辑内容'),
            style: OutlinedButton.styleFrom(
              foregroundColor: isDark ? Colors.white : Colors.black87,
              side: BorderSide(
                color: isDark
                    ? Colors.white.withValues(alpha: 0.14)
                    : Colors.black.withValues(alpha: 0.08),
              ),
              minimumSize: const Size.fromHeight(44),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: FilledButton.icon(
            onPressed: _resolveMarketPost,
            icon: const Icon(Icons.check_circle_outline, size: 18),
            label: Text(_marketCompleteLabel(post.postType)),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF16A34A),
              minimumSize: const Size.fromHeight(44),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildActionButton({
    required IconData icon,
    required Color color,
    required String label,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  // ---- 联系方式（集市复用） ----

  Widget _buildContactChip(String contact, bool isDark) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF222731) : const Color(0xFFF8F9FA),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.06)
              : Colors.black.withValues(alpha: 0.05),
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Theme.of(context).primaryColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              Icons.alternate_email_rounded,
              size: 20,
              color: Theme.of(context).primaryColor,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '联系方式',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: isDark ? Colors.white54 : Colors.grey[500],
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  contact,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.3,
                    color: isDark ? Colors.white : Colors.black87,
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: isDark ? Colors.white10 : Colors.white,
              borderRadius: BorderRadius.circular(20),
              boxShadow: isDark
                  ? []
                  : [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.03),
                        blurRadius: 4,
                        offset: const Offset(0, 2),
                      ),
                    ],
            ),
            child: Row(
              children: [
                Icon(
                  Icons.copy_rounded,
                  size: 14,
                  color: isDark ? Colors.white70 : Colors.black54,
                ),
                const SizedBox(width: 4),
                Text(
                  '一键复制',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: isDark ? Colors.white70 : Colors.black54,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---- 评论区 ----

  Widget _buildCommentsHeader(bool isDark) {
    return Row(
      children: [
        Icon(
          Icons.forum_outlined,
          size: 18,
          color: isDark ? Colors.white30 : Colors.grey[500],
        ),
        const SizedBox(width: 8),
        Text(
          '全部评论 ${_replies.length}',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: isDark ? Colors.white38 : Colors.grey[500],
          ),
        ),
      ],
    );
  }

  Widget _buildCompactReplies(bool isDark) {
    if (_replies.isEmpty) return _buildNoComments(isDark);
    final threads = _buildThreads();
    return Column(
      children: threads
          .take(4)
          .map((t) => _buildReplyThread(t, isDark, compact: true, depth: 0))
          .toList(),
    );
  }

  Widget _buildFullReplies(bool isDark) {
    if (_replies.isEmpty) return _buildNoComments(isDark);
    final threads = _buildThreads();
    return Column(
      children: threads
          .map((t) => _buildReplyThread(t, isDark, compact: false, depth: 0))
          .toList(),
    );
  }

  /// 将回复构建为楼中楼结构：顶级评论 + 所有子回复扁平展示
  List<_ReplyThread> _buildThreads() {
    final childMap = <int, List<Reply>>{};
    for (final r in _replies) {
      if (r.parentReplyId != null) {
        childMap.putIfAbsent(r.parentReplyId!, () => []).add(r);
      }
    }

    // 扁平收集所有子回复（不管嵌套多深）
    List<Reply> flattenChildren(int parentId) {
      final directChildren = childMap[parentId] ?? [];
      final result = <Reply>[];
      for (final child in directChildren) {
        result.add(child);
        // 不再递归，把所有层级的回复都收集到同一层级
      }
      return result;
    }

    _ReplyThread buildNode(Reply reply) {
      // 所有子回复扁平化
      final flatChildren = flattenChildren(reply.id);
      return _ReplyThread(parent: reply, children: flatChildren);
    }

    final topLevel = _replies.where((r) => r.parentReplyId == null).toList();
    return topLevel.map(buildNode).toList();
  }

  Widget _buildNoComments(bool isDark) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32),
      child: Center(
        child: Column(
          children: [
            Icon(
              Icons.chat_bubble_outline,
              size: 36,
              color: isDark ? Colors.white24 : Colors.grey[300],
            ),
            const SizedBox(height: 10),
            Text(
              '还没有评论，来说点什么吧',
              style: TextStyle(
                fontSize: 13,
                color: isDark ? Colors.white30 : Colors.grey[400],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildReplyThread(
    _ReplyThread thread,
    bool isDark, {
    bool compact = false,
    int depth = 0,
  }) {
    // 获取该顶级评论的所有子回复（扁平化）
    final childMap = <int, List<Reply>>{};
    for (final r in _replies) {
      if (r.parentReplyId != null) {
        childMap.putIfAbsent(r.parentReplyId!, () => []).add(r);
      }
    }
    final allChildren = childMap[thread.parent.id] ?? [];
    final isExpanded = _expandedThreads.contains(thread.parent.id);
    final visibleChildren =
        !isExpanded ? allChildren.take(2).toList() : allChildren;
    final hasMore = !isExpanded && allChildren.length > 2;

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 主评论
          _buildMainReply(thread.parent, isDark),
          // 子回复区域（扁平化展示）
          if (visibleChildren.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(left: 44, top: 4),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: isDark
                    ? Colors.white.withValues(alpha: 0.03)
                    : const Color(0xFFF8F9FA),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ...visibleChildren.map(
                    (child) => _buildChildReply(child, isDark, depth: 0),
                  ),
                  if (hasMore)
                    GestureDetector(
                      onTap: () {
                        if (mounted)
                          setState(() {
                            _expandedThreads.add(thread.parent.id);
                          });
                      },
                      child: Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          '共 ${allChildren.length} 条回复，点击查看全部',
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context).primaryColor,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// 主评论（顶级）
  Widget _buildMainReply(Reply r, bool isDark) {
    final currentUser = context.read<AuthProvider>().user;
    final isOwn = currentUser?.id == r.authorId;
    return _buildReplyAnchor(
      reply: r,
      isDark: isDark,
      child: GestureDetector(
        onTap: () => _openReplyComposer(
          parentReplyId: r.id,
          replyToName: r.author?.nickname,
          replyToUserId: r.authorId,
        ),
        onLongPress: () => _showReplyActionSheet(r, isOwn, isDark),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GestureDetector(
              onTap: () {
                if (r.author != null) {
                  _openAuthorHome(r.author!.id);
                }
              },
              child: CachedAvatar(
                radius: 18,
                imageUrl: r.author?.avatar.isNotEmpty == true
                    ? ApiConstants.fullUrl(r.author!.avatar)
                    : null,
                fallbackText: r.author?.nickname,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        r.author?.nickname ?? '匿名',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: isDark
                              ? Colors.white.withValues(alpha: 0.82)
                              : Colors.black87,
                        ),
                      ),
                      if (r.author != null) ...[
                        const SizedBox(width: 4),
                        _buildLevelBadgeSmall(r.author!, isDark),
                      ],
                      const SizedBox(width: 8),
                      Text(
                        _formatTime(r.createdAt),
                        style: TextStyle(
                          fontSize: 11,
                          color: isDark ? Colors.white24 : Colors.grey[400],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  SelectionContainer.disabled(
                    child: Text(
                      r.content,
                      style: TextStyle(
                        fontSize: 14,
                        height: 1.55,
                        color: isDark ? Colors.white70 : Colors.grey[800],
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Icon(
                        Icons.reply,
                        size: 13,
                        color: isDark ? Colors.white24 : Colors.grey[400],
                      ),
                      const SizedBox(width: 3),
                      Text(
                        '回复',
                        style: TextStyle(
                          fontSize: 11,
                          color: isDark ? Colors.white24 : Colors.grey[400],
                        ),
                      ),
                      const Spacer(),
                      GestureDetector(
                        onTap: () => showReportSheet(
                          context,
                          targetId: r.id,
                          targetType: 'reply',
                        ),
                        child: Icon(
                          Icons.more_horiz,
                          size: 16,
                          color: isDark ? Colors.white24 : Colors.grey[300],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 子回复（楼中楼）
  Widget _buildChildReply(Reply r, bool isDark, {int depth = 0}) {
    // 从 content 中解析 @username
    final contentWidget = _buildChildContent(r, isDark);
    // 回复按钮指向顶级评论（楼中楼的根），避免多层嵌套
    final threadParentId = _findTopLevelParentId(r);
    final currentUser = context.read<AuthProvider>().user;
    final isOwn = currentUser?.id == r.authorId;
    return _buildReplyAnchor(
      reply: r,
      isDark: isDark,
      child: GestureDetector(
        onTap: () => _openReplyComposer(
          parentReplyId: threadParentId,
          replyToName: r.author?.nickname,
          replyToUserId: r.authorId,
        ),
        onLongPress: () => _showReplyActionSheet(r, isOwn, isDark),
        child: Padding(
          padding: EdgeInsets.only(bottom: 8, left: depth * 4.0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GestureDetector(
                onTap: () {
                  if (r.author != null) {
                    _openAuthorHome(r.author!.id);
                  }
                },
                child: CachedAvatar(
                  radius: 10,
                  imageUrl: r.author?.avatar.isNotEmpty == true
                      ? ApiConstants.fullUrl(r.author!.avatar)
                      : null,
                  fallbackText: r.author?.nickname,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          r.author?.nickname ?? '匿名',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: isDark
                                ? Colors.white.withValues(alpha: 0.70)
                                : Colors.black87,
                          ),
                        ),
                        if (r.author != null) ...[
                          const SizedBox(width: 4),
                          _buildLevelBadgeSmall(r.author!, isDark),
                        ],
                        const SizedBox(width: 8),
                        Text(
                          _formatTime(r.createdAt),
                          style: TextStyle(
                            fontSize: 10,
                            color: isDark ? Colors.white24 : Colors.grey[400],
                          ),
                        ),
                        const Spacer(),
                        Text(
                          '回复',
                          style: TextStyle(
                            fontSize: 10,
                            color: isDark ? Colors.white24 : Colors.grey[400],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    contentWidget,
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildReplyAnchor({
    required Reply reply,
    required Widget child,
    required bool isDark,
  }) {
    final replyKey = _replyKeys.putIfAbsent(
      reply.id,
      GlobalKey.new,
    );
    final isHighlighted = _highlightedReplyId == reply.id;

    return AnimatedContainer(
      key: replyKey,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        color: isHighlighted
            ? Colors.amber.withValues(
                alpha: isDark ? 0.22 : 0.16,
              )
            : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
      ),
      child: child,
    );
  }

  /// 解析子回复内容中的 @用户名 并高亮
  Widget _buildChildContent(Reply r, bool isDark) {
    final content = r.content;
    final atRegex = RegExp(r'^@(\S+)\s');
    final match = atRegex.firstMatch(content);

    Widget textWidget;
    if (match != null) {
      final atName = match.group(1)!;
      final rest = content.substring(match.end);
      textWidget = Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '@$atName ',
              style: TextStyle(
                fontSize: 13,
                height: 1.4,
                color: Theme.of(context).primaryColor,
                fontWeight: FontWeight.w500,
              ),
            ),
            TextSpan(
              text: rest,
              style: TextStyle(
                fontSize: 13,
                height: 1.4,
                color: isDark ? Colors.white60 : Colors.grey[700],
              ),
            ),
          ],
        ),
      );
    } else {
      textWidget = Text(
        content,
        style: TextStyle(
          fontSize: 13,
          height: 1.4,
          color: isDark ? Colors.white60 : Colors.grey[700],
        ),
      );
    }
    // 禁用文字选择，让行级长按直接弹出操作菜单
    return SelectionContainer.disabled(child: textWidget);
  }

  // ---- 回复输入（集市保留） ----

  Widget _buildReplyBar(bool isDark) {
    if (!_isReplyComposerOpen) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      decoration: BoxDecoration(
        color: isDark
            ? const Color(0xFF1E1E32).withValues(alpha: 0.92)
            : Colors.white.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 12,
            offset: const Offset(0, -3),
          ),
        ],
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
          child: Row(
            children: [
              GestureDetector(
                onTap: () {
                  _replyController.clear();
                  _replyFocus.unfocus();
                  if (mounted)
                    setState(() {
                      _isReplyComposerOpen = false;
                      _parentReplyId = null;
                      _replyToName = null;
                      _replyToUserId = null;
                    });
                },
                child: Container(
                  width: 36,
                  height: 36,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: isDark
                        ? Colors.white10
                        : Colors.black.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.close,
                    size: 18,
                    color: isDark ? Colors.white54 : Colors.grey[700],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _replyController,
                  focusNode: _replyFocus,
                  decoration: InputDecoration(
                    hintText: _replyToName != null
                        ? '回复 @$_replyToName...'
                        : '写下你的想法...',
                    hintStyle: TextStyle(
                      color: isDark ? Colors.white30 : Colors.grey[400],
                      fontSize: 14,
                    ),
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                  ),
                  style: TextStyle(
                    fontSize: 14,
                    color: isDark ? Colors.white : Colors.black87,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              GestureDetector(
                onTap: _isSending ? null : _sendReply,
                child: Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    gradient: _isSending
                        ? const LinearGradient(
                            colors: [Color(0xFF9CA3AF), Color(0xFF9CA3AF)],
                          )
                        : const LinearGradient(
                            colors: [Color(0xFF667EEA), Color(0xFF764BA2)],
                          ),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: _isSending
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(
                          Icons.send_rounded,
                          color: Colors.white,
                          size: 20,
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---- 工具 ----

  Color _creditColor(int score) {
    if (score >= 90) return const Color(0xFF4CAF50);
    if (score >= 70) return const Color(0xFFFF9800);
    return const Color(0xFFF44336);
  }

  String _formatTime(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes}分钟前';
    if (diff.inHours < 24) return '${diff.inHours}小时前';
    if (diff.inDays < 7) return '${diff.inDays}天前';
    return '${dt.month}/${dt.day}';
  }

  String _marketCompleteLabel(String postType) {
    switch (postType) {
      case 'sell':
        return '已售出';
      case 'buy':
        return '已买到';
      case 'proxy':
        return '已完成';
      case 'lost':
      case 'found':
        return '已解决';
      default:
        return '已处理';
    }
  }

  /// 查找回复的顶级评论id（楼中楼的根）
  int _findTopLevelParentId(Reply r) {
    // 查找这条回复的顶级父评论
    final parentMap = <int, int>{}; // replyId -> parentReplyId
    for (final reply in _replies) {
      if (reply.parentReplyId != null) {
        parentMap[reply.id] = reply.parentReplyId!;
      }
    }
    // 循环向上找到顶级评论
    int currentId = r.id;
    while (parentMap.containsKey(currentId)) {
      currentId = parentMap[currentId]!;
    }
    // currentId 现在是顶级评论的id
    return currentId;
  }

  bool _isCurrentUserPostOwner() {
    final post = _post;
    final currentUser = context.read<AuthProvider>().user;
    return post != null &&
        currentUser != null &&
        currentUser.id == post.authorId;
  }

  bool _canUseOwnerMarketActions() {
    return widget.isMarket && _isCurrentUserPostOwner();
  }

  List<String> _resolvedImageUrls(Post post) {
    return post.images
        .map((image) => ApiConstants.fullUrl(image.url))
        .where((url) => url.trim().isNotEmpty)
        .toList();
  }

  Widget _buildLevelBadge(User user, bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: Color(user.levelColorValue).withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        user.levelLabel,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: Color(user.levelColorValue),
        ),
      ),
    );
  }

  Widget _buildLevelBadgeSmall(User user, bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: Color(user.levelColorValue).withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        user.levelLabel,
        style: TextStyle(
          fontSize: 8,
          fontWeight: FontWeight.w700,
          color: Color(user.levelColorValue),
        ),
      ),
    );
  }

  void _openReplyComposer({
    int? parentReplyId,
    String? replyToName,
    int? replyToUserId,
  }) {
    if (mounted)
      setState(() {
        _isReplyComposerOpen = true;
        _parentReplyId = parentReplyId;
        _replyToName = replyToName;
        _replyToUserId = replyToUserId;
        if (replyToName != null && replyToName.isNotEmpty) {
          _replyController.text = '@$replyToName ';
          _replyController.selection = TextSelection.fromPosition(
            TextPosition(offset: _replyController.text.length),
          );
        }
      });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _replyFocus.requestFocus();
      }
    });
  }

  void _showReplyActionSheet(Reply r, bool isOwn, bool isDark) {
    showModalBottomSheet(
      context: context,
      backgroundColor: isDark ? const Color(0xFF1E1E32) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(top: 12),
              decoration: BoxDecoration(
                color: isDark ? Colors.white24 : Colors.grey[300],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            ListTile(
              leading: Icon(
                Icons.copy,
                color: isDark ? Colors.white70 : Colors.black87,
              ),
              title: Text(
                '复制',
                style: TextStyle(
                  color: isDark ? Colors.white70 : Colors.black87,
                ),
              ),
              onTap: () {
                Clipboard.setData(ClipboardData(text: r.content));
                Navigator.pop(ctx);
                AppFeedback.showSnackBar(context, '已复制');
              },
            ),
            if (isOwn)
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.red),
                title: const Text('删除', style: TextStyle(color: Colors.red)),
                onTap: () async {
                  Navigator.pop(ctx);
                  await _deleteReply(r);
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _deleteReply(Reply r) async {
    final confirmed = await AppFeedback.confirmDanger(
      context,
      title: '删除回复',
      message: '确定要删除这条回复吗？',
    );
    if (!confirmed) return;
    try {
      await _dio.delete('/replies/${r.id}');
      if (mounted) {
        AppFeedback.showSnackBar(context, '已删除');
        if (_post != null && _post!.replyCount > 0) {
          if (mounted)
            setState(() {
              _post = _post!.copyWith(replyCount: _post!.replyCount - 1);
            });
          context.read<PostProvider>().updatePostInCache(_post!);
        }
        _loadReplies();
      }
    } on DioException catch (e) {
      final msg = AppFeedback.dioErrorMessage(e, fallback: '删除失败');
      if (mounted) {
        AppFeedback.showSnackBar(context, msg, isError: true);
      }
    }
  }

  Future<void> _loadReplies() async {
    try {
      final repliesResponse = await _dio.get('/posts/${widget.postId}/replies');
      if (mounted)
        setState(() {
          _replies = (repliesResponse.data as List)
              .map((e) => Reply.fromJson(e))
              .toList();
        });
    } on DioException catch (e) {
      final msg = AppFeedback.dioErrorMessage(e, fallback: '加载回复失败');
      if (mounted) {
        AppFeedback.showSnackBar(context, msg, isError: true);
      }
    }
  }
}

/// 楼中楼数据结构（扁平化子回复）
class _ReplyThread {
  final Reply parent;
  final List<Reply> children; // 直接子回复列表，不再递归
  _ReplyThread({required this.parent, required this.children});
}
