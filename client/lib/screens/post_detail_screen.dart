import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:dio/dio.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:provider/provider.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import '../providers/auth_provider.dart';
import '../providers/theme_provider.dart';
import '../models/startup_destination.dart';
import '../services/root_page_state_service.dart';
import '../utils/app_navigator.dart';
import '../theme/app_motion.dart';
import '../config/api_constants.dart';
import '../config/market_contact_type.dart';
import '../config/water_post_taxonomy.dart';
import '../controllers/post_reply_composer_controller.dart';
import '../models/post.dart';
import '../models/reply.dart';
import '../models/user.dart';
import '../models/water_section.dart';
import '../providers/post_provider.dart';
import '../providers/water_moderator_provider.dart';
import '../providers/water_moderation_provider.dart';
import '../providers/water_section_provider.dart';
import '../services/emoji_favorite_service.dart';
import '../utils/app_feedback.dart';
import '../widgets/report_sheet.dart';
import '../widgets/cached_avatar.dart';
import '../widgets/app_action_popup_menu.dart';
import '../widgets/post_media/post_media_view.dart';
import '../widgets/topic_chips.dart';
import '../widgets/post_reply/post_reply_list.dart';
import '../widgets/post_reply_composer.dart';
import '../widgets/emoji/sticker_catalog.dart';
import 'create_post_screen.dart';
import 'image_viewer_screen.dart';
import 'water_category_feed_route.dart';
import 'team/team_recruitment_detail_screen.dart';

import '../utils/app_navigation.dart';

const _ignoredLegacyWaterTagNames = {'其他', '其它', '默认', '未分类', '综合'};

class PostDetailScreen extends StatefulWidget {
  final int postId;
  final bool isMarket;
  final Post? initialPost;
  final int? targetReplyId;
  final bool isDesktopSplitMode;
  final bool hideBackButton;
  final bool focusReplyComposer;
  final ValueChanged<int>? onAuthorTap;

  const PostDetailScreen({
    super.key,
    required this.postId,
    this.isMarket = false,
    this.initialPost,
    this.targetReplyId,
    this.isDesktopSplitMode = false,
    this.hideBackButton = false,
    this.focusReplyComposer = false,
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

class _PostDetailScreenState extends State<PostDetailScreen> with RouteAware {
  PageRoute<dynamic>? _subscribedRoute;
  late Dio _dio;
  Post? _post;
  List<Reply> _replies = [];
  bool _isLoading = true;
  String? _errorMessage;
  final _replyComposerController = PostReplyComposerController();
  late final Listenable _replyComposerActivity;
  bool _isSending = false;
  bool _hasPendingFeaturedApp = false;

  int? _activeTargetReplyId;

  final Map<int, GlobalKey> _replyKeys = {};
  bool _hasScrolledToTarget = false;
  int? _highlightedReplyId;
  Timer? _highlightTimer;

  // ---- 评论排序 + 点赞状态 ----

  /// 当前评论排序：'hot' | 'latest'。
  String _replySort = 'hot';
  bool _isRepliesLoading = false;

  /// 评论分页状态：服务端总数、下一页游标、是否还有更多、加载更多中。
  int _totalReplies = 0;
  String? _repliesNextCursor;
  bool _repliesHasMore = false;
  bool _loadingMoreReplies = false;

  /// 回复请求版本号：切换排序后旧请求返回时直接丢弃。
  int _replyRequestVersion = 0;

  /// 在途的评论点赞 mutation：replyId -> 本次 mutation 的目标点赞状态。
  /// 同时充当防连点锁；列表重载时用它覆盖服务端旧状态，避免点赞闪烁。
  final Map<int, bool> _pendingReplyLikeTargets = {};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute<dynamic> && !identical(route, _subscribedRoute)) {
      if (_subscribedRoute != null) {
        appRouteObserver.unsubscribe(this);
      }
      _subscribedRoute = route;
      appRouteObserver.subscribe(this, route);
    }
  }

  @override
  void didPush() {
    _saveCurrentPageAsLastPage();
  }

  @override
  void initState() {
    super.initState();
    _replyComposerActivity = Listenable.merge([
      _replyComposerController,
      _replyComposerController.focusNode,
    ]);
    _dio = context.read<AuthProvider>().dio;
    if (widget.initialPost != null) {
      _post = widget.initialPost;
      _isLoading = false;
    }
    _activeTargetReplyId = widget.targetReplyId;
    _loadPost();
    if (widget.focusReplyComposer) {
      // 等详情页首帧完成后再展开评论输入框并聚焦，
      // 避免在路由/键盘尚未就绪时“碰运气”等待。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (!context.read<AuthProvider>().isLoggedIn) return;
        _replyComposerController.open();
      });
    }
  }

  /// 仅在 `lastPage` 模式下，把当前帖子详情保存为 lastPage。
  /// 最佳努力：读取失败（如测试用 Fake Provider）时静默跳过，不打断页面。
  void _saveCurrentPageAsLastPage() {
    try {
      final theme = context.read<ThemeProvider>();
      if (theme.startupDestination != StartupDestinationMode.lastPage) return;
      final accountId = context.read<AuthProvider>().user?.id;
      if (accountId == null || accountId <= 0 || widget.postId <= 0) return;
      unawaited(RootPageStateStore.instance.saveLastPage(
        RestorablePageState(
          type: RestorablePageType.post,
          arguments: <String, dynamic>{
            'postId': widget.postId,
            'underlyingRootTab': currentHomeTabIndex.value,
          },
          accountId: accountId,
        ),
      ));
    } catch (_) {
      // 忽略：不影响正常浏览。
    }
  }

  Future<void> _loadWaterSectionPermission({bool forceRefresh = false}) async {
    final post = _post ?? widget.initialPost;
    if (post == null || post.boardId != 1 || post.postType.isEmpty) return;
    if (!mounted) return;
    await context
        .read<WaterModeratorProvider>()
        .loadMyPermission(post.postType, forceRefresh: forceRefresh);
  }

  @override
  void dispose() {
    if (_subscribedRoute != null) {
      appRouteObserver.unsubscribe(this);
    }
    _replyComposerController.dispose();
    _highlightTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadPost() async {
    // 有 initialPost 时首帧已经显示完整帖子：刷新在后台进行，
    // 不再把 _isLoading 切回 true 遮住已有内容（stale-while-refresh）。
    final hasInitialPost = _post != null;
    if (mounted)
      setState(() {
        if (!hasInitialPost) _isLoading = true;
        _errorMessage = null;
      });
    try {
      final response = await _dio.get('/posts/${widget.postId}');
      final fetchedPost = Post.fromJson(response.data);
      final recruitmentId = fetchedPost.teamRecruitment?.recruitmentId;
      if (recruitmentId != null && recruitmentId > 0 && mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => TeamRecruitmentDetailScreen(
              recruitmentId: recruitmentId,
            ),
          ),
        );
        return;
      }

      // 精华申请状态只影响菜单角标，不应阻塞帖子主体上屏，改为独立后台请求。
      _loadFeaturedApplicationStatus();

      final fallbackPost = widget.initialPost;
      final mergedPost = fallbackPost != null &&
              fallbackPost.images.length > fetchedPost.images.length
          ? fetchedPost.copyWith(images: fallbackPost.images)
          : fetchedPost;
      if (mounted)
        setState(() {
          _post = mergedPost;
          _isLoading = false;
        });
      // 同步到外部列表以更新浏览量等数据
      if (mounted) {
        context.read<PostProvider>().updatePostInCache(_post!);
      }
      // 评论区独立加载：切换 Hot/Latest 只刷新回复，不重复拉帖子详情。
      await _loadReplies(sort: _replySort);
      await _loadWaterSectionPermission(forceRefresh: true);
      if (_activeTargetReplyId != null && !_hasScrolledToTarget) {
        await _prepareTargetReplyAndScroll();
      }
    } on DioException catch (e) {
      final msg = AppFeedback.dioErrorMessage(e, fallback: '加载帖子失败');
      if (mounted) {
        setState(() {
          _isLoading = false;
          if (!hasInitialPost) {
            _errorMessage = msg;
          }
        });
        if (hasInitialPost) {
          // 保留已有帖子内容 + 局部失败提示，弱网下不把整页换成错误页。
          AppFeedback.showSnackBar(context, '内容刷新失败', isError: true);
          _loadReplies(sort: _replySort);
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          if (!hasInitialPost) {
            _errorMessage = '加载失败: $e';
          }
        });
        if (hasInitialPost) {
          AppFeedback.showSnackBar(context, '内容刷新失败', isError: true);
          _loadReplies(sort: _replySort);
        }
      }
    }
  }

  Future<void> _loadFeaturedApplicationStatus() async {
    try {
      final statusResponse =
          await _dio.get('/posts/${widget.postId}/featured-application-status');
      if (mounted) {
        setState(() {
          _hasPendingFeaturedApp = statusResponse.data['has_pending'] == true;
        });
      }
    } catch (e) {
      // ignore status check failure
    }
  }

  Future<void> _prepareTargetReplyAndScroll() async {
    final targetId = _activeTargetReplyId;
    if (targetId == null) return;

    // 快速路径：目标已在已加载分页中 → 原有滚动/高亮逻辑。
    final loadedTarget = _replies.where((r) => r.id == targetId).firstOrNull;
    if (loadedTarget != null) {
      setState(() {}); // 触发重新渲染，确保子组件挂载
      _scheduleScrollToTarget(targetId, 3);
      return;
    }

    // 精确路径：目标不在已加载分页（第 6 页以后的根 / 第 51+ 条子回复）时，
    // 用 context 接口拿目标与线程根，直接打开楼中楼 sheet 锚定目标，
    // 不再盲翻分页页。
    final Reply target;
    final Reply root;
    try {
      final resp =
          await _dio.get('/posts/${widget.postId}/replies/$targetId/context');
      final data = resp.data;
      if (data is! Map<String, dynamic>) return;
      final rawTarget = data['reply'];
      final rawRoot = data['root_reply'];
      if (rawTarget is! Map<String, dynamic> ||
          rawRoot is! Map<String, dynamic>) {
        return;
      }
      target = Reply.fromJson(rawTarget);
      root = Reply.fromJson(rawRoot);
    } on DioException catch (e) {
      // 深链目标失效时仍可正常浏览帖子；仅对明确的删除/不存在做轻提示。
      if (mounted && e.response?.statusCode == 404) {
        AppFeedback.showSnackBar(context, '该回复可能已删除');
      }
      return;
    } catch (_) {
      return;
    }
    if (!mounted) return;
    // 目标是根评论本身时打开线程 sheet；子回复目标则锚定到该条并高亮。
    final anchored = target.parentReplyId != null;
    await _showReplyThreadSheet(
      parentReply: root,
      anchorReply: anchored ? target : null,
    );
  }

  void _scheduleScrollToTarget(int targetId, int retries) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      final key = _replyKeys[targetId];
      final context = key?.currentContext;

      if (context != null) {
        final reduceMotion =
            MediaQuery.maybeOf(context)?.disableAnimations ?? false;
        Scrollable.ensureVisible(
          context,
          duration: reduceMotion ? Duration.zero : AppMotion.page,
          curve: AppMotion.incoming,
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
    final current = _post;
    if (current == null) return;
    final provider = context.read<PostProvider>();
    if (provider.isLikePending(current.id)) return;
    final result = await provider.toggleLikeOptimistic(current);
    if (!mounted) return;
    setState(() {
      _post = switch (result.status) {
        LikeMutationStatus.success => result.optimisticPost,
        LikeMutationStatus.conflict =>
          result.reconciledPost ?? result.optimisticPost,
        LikeMutationStatus.failed ||
        LikeMutationStatus.pending =>
          result.originalPost,
      };
      if (_post != null) {
        // 保持与当前回复列表一致，避免 count 被乐观副本覆盖。
        final replyTotal = _totalReplies > 0 ? _totalReplies : _replies.length;
        _post = _post!.copyWith(replyCount: replyTotal);
      }
    });
  }

  Future<Reply?> _createReplyFromDraft(PostReplyDraft draft) async {
    if (draft.isEmpty) return null;
    if (!context.read<AuthProvider>().isLoggedIn) {
      _openReplyLogin();
      return null;
    }

    final fileIds = <int>[];
    if (draft.localImage != null) {
      fileIds.add(
        await _uploadLocalImage(
          draft.localImage!.path,
          draft.localImage!.name,
        ),
      );
    } else if (draft.favoriteImage != null) {
      fileIds.add(await _uploadFavoriteImage(draft.favoriteImage!));
    }
    return _submitReplyContent(
      content: draft.text,
      stickerId: draft.sticker?.id,
      fileIds: fileIds,
      parentReplyId: draft.parentReplyId,
      replyToUserId: draft.replyToUserId,
      // 底部输入区回复的是根评论本身；楼中楼 sheet 会传精确目标。
      replyToReplyId: draft.replyToReplyId ?? draft.parentReplyId,
    );
  }

  Future<bool> _sendReplyDraft(PostReplyDraft draft) async {
    if (_isSending || draft.isEmpty) return false;
    if (!context.read<AuthProvider>().isLoggedIn) {
      _openReplyLogin();
      return false;
    }

    setState(() => _isSending = true);
    try {
      final created = await _createReplyFromDraft(draft);
      return created != null;
    } on DioException catch (error) {
      if (mounted) {
        AppFeedback.showSnackBar(
          context,
          AppFeedback.dioErrorMessage(error, fallback: '评论发送失败'),
          isError: true,
        );
      }
      return false;
    } catch (error) {
      if (mounted) {
        AppFeedback.showSnackBar(context, '评论发送失败', isError: true);
      }
      debugPrint('发送评论失败: $error');
      return false;
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  void _openReplyLogin() {
    Navigator.of(context).pushNamed('/login');
  }

  Future<int> _uploadFavoriteImage(EmojiFavoriteItem favorite) async {
    final imageUrl = favorite.imageUrl?.trim();
    if (imageUrl == null || imageUrl.isEmpty) {
      throw StateError('收藏图片地址为空');
    }
    final file = await DefaultCacheManager().getSingleFile(
      ApiConstants.fullUrl(imageUrl),
      headers: _favoriteImageHeaders(),
    );
    final pathSegments = Uri.tryParse(imageUrl)?.pathSegments ?? const [];
    final originalName = pathSegments.isEmpty ? '' : pathSegments.last.trim();
    final fileName = originalName.isEmpty ? 'favorite-image.jpg' : originalName;
    final response = await _dio.post(
      '/upload',
      data: FormData.fromMap({
        'file': await MultipartFile.fromFile(file.path, filename: fileName),
      }),
    );
    final rawFileId =
        response.data is Map ? (response.data as Map)['file_id'] : null;
    final fileId = rawFileId is num
        ? rawFileId.toInt()
        : int.tryParse(rawFileId?.toString() ?? '');
    if (fileId == null || fileId <= 0) {
      throw StateError('服务器未返回有效图片 ID');
    }
    return fileId;
  }

  Map<String, String> _favoriteImageHeaders() {
    final token = context.read<AuthProvider>().token?.trim();
    if (token == null || token.isEmpty) return const <String, String>{};
    return <String, String>{'Authorization': 'Bearer $token'};
  }

  Future<int> _uploadLocalImage(String path, String fileName) async {
    final response = await _dio.post(
      '/upload',
      data: FormData.fromMap({
        'file': await MultipartFile.fromFile(path, filename: fileName),
      }),
    );
    final rawFileId =
        response.data is Map ? (response.data as Map)['file_id'] : null;
    final fileId = rawFileId is num
        ? rawFileId.toInt()
        : int.tryParse(rawFileId?.toString() ?? '');
    if (fileId == null || fileId <= 0) {
      throw StateError('服务器未返回有效图片 ID');
    }
    return fileId;
  }

  Future<Reply?> _submitReplyContent({
    required String content,
    String? stickerId,
    List<int> fileIds = const [],
    required int? parentReplyId,
    required int? replyToUserId,
    int? replyToReplyId,
  }) async {
    int? tempReplyId;

    void rollbackOptimisticReply() {
      if (!mounted || tempReplyId == null) return;
      setState(() {
        _replies.removeWhere((reply) => reply.id == tempReplyId);
        if (_post != null) {
          _post = _post!.copyWith(replyCount: _post!.replyCount - 1);
        }
      });
      if (_post != null) {
        context.read<PostProvider>().updatePostInCache(_post!);
      }
    }

    // 乐观更新：立即在本地插入评论
    final user = context.read<AuthProvider>().user;
    if (user != null && _post != null && fileIds.isEmpty) {
      tempReplyId = -DateTime.now().microsecondsSinceEpoch;
      final tempReply = Reply(
        id: tempReplyId,
        postId: widget.postId,
        authorId: user.id,
        content: content,
        stickerId: stickerId,
        createdAt: DateTime.now(),
        author: User(
          id: user.id,
          studentId: user.studentId,
          nickname: user.nickname,
          avatar: user.avatar,
          createdAt: DateTime.now(),
        ),
        parentReplyId: parentReplyId,
      );
      setState(() {
        _replies.insert(0, tempReply);
        _post = _post!.copyWith(replyCount: _post!.replyCount + 1);
      });
      context.read<PostProvider>().updatePostInCache(_post!);
    }

    // 后台静默发送
    try {
      final formData = FormData.fromMap({
        'content': content,
        if (stickerId != null) 'sticker_id': stickerId,
        if (fileIds.isNotEmpty) 'file_ids': fileIds.join(','),
        if (parentReplyId != null) 'parent_reply_id': parentReplyId.toString(),
        if (replyToUserId != null) 'reply_to_user_id': replyToUserId.toString(),
        if (replyToReplyId != null)
          'reply_to_reply_id': replyToReplyId.toString(),
      });
      final createResponse =
          await _dio.post('/posts/${widget.postId}/replies', data: formData);
      final createdReply = createResponse.data is Map<String, dynamic>
          ? Reply.fromJson(createResponse.data as Map<String, dynamic>)
          : null;
      if (mounted) {
        _showReplyRewardFeedback(createdReply);
      }
      // 静默刷新获取真实 ID（沿用当前排序，避免切回 hot 前的旧顺序残留）。
      await _loadReplies(sort: _replySort);
      return createdReply;
    } on DioException catch (e) {
      if (mounted) {
        rollbackOptimisticReply();
        AppFeedback.showSnackBar(
          context,
          AppFeedback.dioErrorMessage(e, fallback: '发送失败'),
          isError: true,
        );
      }
      return null;
    } catch (_) {
      if (mounted) {
        rollbackOptimisticReply();
        AppFeedback.showSnackBar(context, '发送失败', isError: true);
      }
      return null;
    }
  }

  ExpAward? _firstAwardWhere(
    List<ExpAward> awards,
    bool Function(ExpAward award) test,
  ) {
    for (final award in awards) {
      if (test(award)) return award;
    }
    return null;
  }

  void _showReplyRewardFeedback(Reply? reply) {
    final awards = reply?.expAwards ?? const <ExpAward>[];
    if (awards.isEmpty) return;
    final globalAward = _firstAwardWhere(awards, (a) => a.scope == 'global');
    final sectionAward =
        _firstAwardWhere(awards, (a) => a.scope == 'water_section');
    final lines = <String>['回复成功'];
    final expParts = <String>[];

    if (globalAward != null && globalAward.exp > 0) {
      expParts.add('全站经验 +${globalAward.exp}');
    }
    if (sectionAward != null && sectionAward.exp > 0) {
      final sectionName = sectionAward.sectionTitle.isNotEmpty
          ? sectionAward.sectionTitle
          : waterCategoryLabelOf(_post?.postType ?? '');
      expParts.add('$sectionName经验 +${sectionAward.exp}');
    }
    if (expParts.isNotEmpty) {
      lines.add(expParts.join(' · '));
    }
    if (sectionAward != null && sectionAward.levelUp) {
      final sectionName = sectionAward.sectionTitle.isNotEmpty
          ? sectionAward.sectionTitle
          : waterCategoryLabelOf(_post?.postType ?? '');
      final title = sectionAward.titleAfter.isNotEmpty
          ? '「${sectionAward.titleAfter}」'
          : '';
      lines.add('$sectionName升级到 Lv.${sectionAward.levelAfter}$title');
    } else if (globalAward != null && globalAward.levelUp) {
      lines.add('全站等级升级到 Lv.${globalAward.levelAfter}');
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              lines.first,
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
            for (final line in lines.skip(1)) ...[
              const SizedBox(height: 2),
              Text(line),
            ],
          ],
        ),
      ),
    );
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
    String hint = '请输入原因',
    String confirmText = '确认',
  }) async {
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => _PremiumInputDialog(
        title: title,
        hint: hint,
        confirmText: confirmText,
      ),
    );
    if (result == null || result.isEmpty) return null;
    return result;
  }

  // ── 版块置顶 ──

  Future<void> _sectionPinPost() async {
    final post = _post;
    if (post == null) return;
    final sectionSlug = post.postType;
    if (sectionSlug.isEmpty) return;

    final daysResult = await showDialog<int>(
      context: context,
      builder: (ctx) => _PremiumOptionsDialog<int>(
        title: '版块置顶时长',
        options: const [1, 3, 7],
        labelBuilder: (d) => '$d 天',
      ),
    );
    if (daysResult == null) return;
    final reason = await _askReason(title: '置顶原因', hint: '为什么置顶这篇帖子');
    if (reason == null) return;
    if (reason.length < 2) {
      if (mounted) {
        AppFeedback.showSnackBar(context, '置顶原因至少 2 个字', isError: true);
      }
      return;
    }

    if (!mounted) return;
    final confirmed = await AppFeedback.confirmDanger(
      context,
      title: '版块置顶',
      message: '该帖子会在当前版块内优先展示 $daysResult 天。确认继续吗？',
      confirmText: '确认置顶',
    );
    if (!confirmed) return;

    if (!mounted) return;
    final provider = context.read<WaterModerationProvider>();
    final ok = await provider.pinPost(
      sectionSlug: sectionSlug,
      postId: post.id,
      reason: reason,
      pinnedUntil: DateTime.now().add(Duration(days: daysResult)),
    );
    if (!mounted) return;
    if (ok) {
      AppFeedback.showSnackBar(context, '已置顶到该版块（仅影响当前版块，不影响首页）');
      setState(() => _post = _post?.copyWith(
            waterSectionPinned: true,
          ));
      await context.read<PostProvider>().refreshWaterSectionFeeds(sectionSlug);
      if (mounted) await _loadPost();
    } else {
      AppFeedback.showSnackBar(context, provider.error ?? '置顶失败',
          isError: true);
    }
  }

  Future<void> _sectionUnpinPost() async {
    final post = _post;
    if (post == null) return;
    final sectionSlug = post.postType;
    if (sectionSlug.isEmpty) return;

    if (!mounted) return;
    final confirmed = await AppFeedback.confirmDanger(
      context,
      title: '取消版块置顶',
      message: '确定要取消该帖子在当前版块的置顶吗？',
      confirmText: '取消置顶',
    );
    if (!confirmed) return;

    if (!mounted) return;
    final provider = context.read<WaterModerationProvider>();
    final ok = await provider.unpinPost(
      sectionSlug: sectionSlug,
      postId: post.id,
    );
    if (!mounted) return;
    if (ok) {
      AppFeedback.showSnackBar(context, '已取消版块置顶');
      setState(() => _post = _post?.copyWith(
            waterSectionPinned: false,
          ));
      await context.read<PostProvider>().refreshWaterSectionFeeds(sectionSlug);
      if (mounted) await _loadPost();
    } else {
      AppFeedback.showSnackBar(context, provider.error ?? '取消置顶失败',
          isError: true);
    }
  }

  // ── 版块精华 ──

  Future<void> _sectionFeaturePost() async {
    final post = _post;
    if (post == null) return;
    final sectionSlug = post.postType;
    if (sectionSlug.isEmpty) return;

    final reason = await _askReason(title: '加精原因', hint: '为什么设为精华');
    if (reason == null) return;
    if (reason.length < 2) {
      if (mounted) {
        AppFeedback.showSnackBar(context, '原因至少 2 个字', isError: true);
      }
      return;
    }

    if (!mounted) return;
    final confirmed = await AppFeedback.confirmDanger(
      context,
      title: '版块精华',
      message: '设为精华后将在版块的精华区展示，并会自动提交首页精华审核。确认继续吗？',
      confirmText: '设为精华',
    );
    if (!confirmed) return;

    if (!mounted) return;
    final provider = context.read<WaterModerationProvider>();
    final outcome = await provider.featurePost(
      sectionSlug: sectionSlug,
      postId: post.id,
      reason: reason,
    );
    if (!mounted) return;
    if (outcome.ok) {
      final msg = outcome.warning ??
          (outcome.homePending ? '已入版块精华 · 首页推荐待审核' : '已设为版块精华');
      AppFeedback.showSnackBar(
        context,
        msg,
        isError: outcome.warning != null,
      );
      setState(() => _post = _post?.copyWith(
            waterSectionFeatured: true,
            homeFeaturedPending: outcome.homePending,
          ));
      await context.read<PostProvider>().refreshWaterSectionFeeds(sectionSlug);
      if (mounted) await _loadPost();
    } else {
      AppFeedback.showSnackBar(context, outcome.error ?? '设为精华失败',
          isError: true);
    }
  }

  Future<void> _sectionUnfeaturePost() async {
    final post = _post;
    if (post == null) return;
    final sectionSlug = post.postType;
    if (sectionSlug.isEmpty) return;

    if (!mounted) return;
    final confirmed = await AppFeedback.confirmDanger(
      context,
      title: '取消版块精华',
      message: '确定要取消该帖子的版块精华吗？',
      confirmText: '取消精华',
    );
    if (!confirmed) return;

    if (!mounted) return;
    final provider = context.read<WaterModerationProvider>();
    final ok = await provider.unfeaturePost(
      sectionSlug: sectionSlug,
      postId: post.id,
    );
    if (!mounted) return;
    if (ok) {
      AppFeedback.showSnackBar(context, '已取消版块精华');
      setState(() => _post = _post?.copyWith(
            waterSectionFeatured: false,
          ));
      await context.read<PostProvider>().refreshWaterSectionFeeds(sectionSlug);
      if (mounted) await _loadPost();
    } else {
      AppFeedback.showSnackBar(context, provider.error ?? '取消精华失败',
          isError: true);
    }
  }

  // ── 版主删除 ──

  Future<void> _moderateDeletePost() async {
    final post = _post;
    if (post == null) return;
    final sectionSlug = post.postType;
    if (sectionSlug.isEmpty) return;

    final reason = await _askReason(title: '删除原因', hint: '请填写删除原因（至少 2 个字）');
    if (reason == null || reason.length < 2) {
      if (mounted) {
        AppFeedback.showSnackBar(context, '删除原因至少 2 个字', isError: true);
      }
      return;
    }

    if (!mounted) return;
    final confirmed = await AppFeedback.confirmDanger(
      context,
      title: '版主删除',
      message: '删除后该帖子将从列表隐藏，并记录管理日志。确认继续吗？',
      confirmText: '确认删除',
    );
    if (!confirmed) return;

    if (!mounted) return;
    final provider = context.read<WaterModerationProvider>();
    final ok = await provider.deletePostByModerator(
      sectionSlug: sectionSlug,
      postId: post.id,
      reason: reason,
    );
    if (!mounted) return;
    if (ok) {
      AppFeedback.showSnackBar(context, '帖子已删除');
      await context.read<PostProvider>().refreshWaterSectionFeeds(sectionSlug);
      if (!mounted) return;
      Navigator.pop(context, true);
    } else {
      AppFeedback.showSnackBar(context, provider.error ?? '删除失败',
          isError: true);
    }
  }

  // ── 禁言作者 ──

  Future<void> _muteAuthor() async {
    final post = _post;
    if (post == null) return;
    final sectionSlug = post.postType;
    if (sectionSlug.isEmpty) return;
    if (post.authorId == 0) return;

    final daysResult = await showDialog<int>(
      context: context,
      builder: (ctx) => _PremiumOptionsDialog<int>(
        title: '禁言时长',
        options: const [1, 3, 7],
        labelBuilder: (d) => '$d 天',
      ),
    );
    if (daysResult == null) return;
    final reason = await _askReason(title: '禁言原因', hint: '请填写禁言原因（至少 2 个字）');
    if (reason == null || reason.length < 2) {
      if (mounted) {
        AppFeedback.showSnackBar(context, '禁言原因至少 2 个字', isError: true);
      }
      return;
    }

    if (!mounted) return;
    final confirmed = await AppFeedback.confirmDanger(
      context,
      title: '禁言作者',
      message: '禁言仅在该版块生效。被禁言期间该用户暂时不能在本版块发帖或编辑内容。确认禁言 $daysResult 天吗？',
      confirmText: '确认禁言',
    );
    if (!confirmed) return;

    if (!mounted) return;
    final provider = context.read<WaterModerationProvider>();
    final ok = await provider.muteUser(
      sectionSlug: sectionSlug,
      userId: post.authorId,
      reason: reason,
      until: DateTime.now().add(Duration(days: daysResult)),
    );
    if (!mounted) return;
    if (ok) {
      AppFeedback.showSnackBar(context, '已禁言该用户。如需隐藏内容请另行删除帖子');
      await context.read<WaterModerationProvider>().loadMutes(sectionSlug);
    } else {
      AppFeedback.showSnackBar(context, provider.error ?? '禁言失败',
          isError: true);
    }
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
    final nextStatus = post.postType == 'sell' ? 'sold' : 'closed';
    final postProvider = context.read<PostProvider>();
    final confirmed = await AppFeedback.confirmDanger(
      context,
      title: actionLabel,
      message: '确认后这条发布会保留在主页和集市记录中，并显示为$actionLabel，不会删除这条发布。',
      confirmText: actionLabel,
    );
    if (!confirmed) return;
    final updated = await postProvider.updatePostStatus(
      postId: post.id,
      status: nextStatus,
    );
    if (!mounted) return;
    if (updated != null) {
      setState(() => _post = updated);
      AppFeedback.showSnackBar(context, '已标记为$actionLabel');
    } else {
      AppFeedback.showSnackBar(
        context,
        '$actionLabel失败',
        isError: true,
      );
    }
  }

  Future<void> _markAsSold() async {
    final post = _post;
    if (post == null) return;
    final postProvider = context.read<PostProvider>();
    final confirmed = await AppFeedback.confirmDanger(
      context,
      title: '标记已售出',
      message: '标记后商品会保留在主页和集市记录中，并显示为已售出，不会删除这条发布。',
      confirmText: '标记已售出',
    );
    if (!confirmed) return;

    final updated = await postProvider.updatePostStatus(
      postId: post.id,
      status: 'sold',
    );
    if (!mounted) return;
    if (updated != null) {
      setState(() => _post = updated);
      AppFeedback.showSnackBar(context, '已标记为已售出');
    } else {
      AppFeedback.showSnackBar(context, '标记失败', isError: true);
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
    final overlayStyle =
        (!isDark ? SystemUiOverlayStyle.dark : SystemUiOverlayStyle.light)
            .copyWith(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: Colors.transparent,
    );

    // 桌面分栏模式：保持透明背景
    final bool transparentMode =
        widget.isDesktopSplitMode && widget.hideBackButton;

    return PopScope(
      canPop: true,
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: overlayStyle,
        child: Scaffold(
          resizeToAvoidBottomInset: false,
          backgroundColor: transparentMode
              ? Colors.transparent
              : (isDark ? const Color(0xFF131720) : kCleanWarmBackgroundLight),
          appBar: transparentMode
              ? AppBar(
                  backgroundColor: Colors.transparent,
                  elevation: 0,
                  automaticallyImplyLeading: false,
                )
              : widget.isMarket
                  ? _buildMarketAppBar(
                      isDark,
                      canEdit: canEdit,
                      canDelete: canDelete,
                      isOwn: isOwn,
                      isAdmin: isAdmin,
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
              else
                _buildKeyboardAwareDetail(
                  child: widget.isMarket
                      ? _buildMarketDetail(isDark)
                      : Column(
                          children: [
                            Expanded(
                              child: _buildInputDismissRegion(
                                child: _buildWaterDetail(isDark),
                              ),
                            ),
                            _buildWaterReplyBar(isDark),
                          ],
                        ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Scaffold 不随 IME resize 时，由详情页自己为 Composer 预留键盘 viewport。
  ///
  /// Emoji 面板已经是 Composer 的自定义底部面板，此时不能再叠加系统
  /// viewInsets；Emoji → Keyboard handoff 会在 IME 稳定后由 controller 接管。
  Widget _buildKeyboardAwareDetail({required Widget child}) {
    return AnimatedBuilder(
      animation: _replyComposerActivity,
      child: child,
      builder: (context, child) {
        final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
        final bottomInset =
            _replyComposerController.showEmojiPanel ? 0.0 : keyboardInset;
        return Padding(
          padding: EdgeInsets.only(bottom: bottomInset),
          child: child,
        );
      },
    );
  }

  Widget _buildInputDismissRegion({required Widget child}) {
    return AnimatedBuilder(
      animation: _replyComposerActivity,
      child: child,
      builder: (context, child) {
        final inputActive = _replyComposerController.focusNode.hasFocus ||
            _replyComposerController.showEmojiPanel;

        return Stack(
          fit: StackFit.expand,
          children: [
            child!,
            Positioned.fill(
              child: IgnorePointer(
                ignoring: !inputActive,
                child: ExcludeSemantics(
                  excluding: !inputActive,
                  child: Semantics(
                    button: true,
                    enabled: inputActive,
                    label: '收起评论输入',
                    onTap: inputActive
                        ? () => _replyComposerController.close()
                        : null,
                    child: GestureDetector(
                      key: const ValueKey('post-detail-input-dismiss-layer'),
                      behavior: HitTestBehavior.opaque,
                      excludeFromSemantics: true,
                      onTap: () => _replyComposerController.close(),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  PreferredSizeWidget _buildMarketAppBar(
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
      titleSpacing: widget.hideBackButton ? 16 : 0,
      title: Text(
        _marketTypeTitle(_post?.postType ?? ''),
        style: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w700,
          color: isDark ? Colors.white : Colors.black87,
        ),
      ),
      actions: [
        if (_post != null)
          _buildPostMoreMenu(
            isDark: isDark,
            canEdit: canEdit,
            canDelete: canDelete,
            isOwn: isOwn,
            isAdmin: isAdmin,
          ),
      ],
    );
  }

  String _marketTypeTitle(String type) {
    switch (type) {
      case 'sell':
        return '出售详情';
      case 'buy':
        return '求购详情';
      case 'lost':
        return '失物详情';
      case 'found':
        return '招领详情';
      case 'proxy':
        return '办事详情';
      case 'exposure':
        return '曝光详情';
      default:
        return '集市详情';
    }
  }

  Future<void> _openWaterCategoryFromDetail() async {
    final sectionSlug = _post?.postType ?? '';
    if (sectionSlug.isEmpty) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => WaterCategoryFeedRoute(sectionSlug: sectionSlug),
      ),
    );
  }

  /// 水帖专用 AppBar：不透明背景 + 分类入口 + 更多菜单
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
      leadingWidth: widget.hideBackButton ? null : 56,
      leading: widget.hideBackButton ? null : const BackButton(),
      titleSpacing: widget.hideBackButton ? 16 : 0,
      title: _buildWaterAppBarCategoryChip(isDark),
      centerTitle: false,
      actions: [
        if (_post != null)
          _buildPostMoreMenu(
            isDark: isDark,
            canEdit: canEdit,
            canDelete: canDelete,
            isOwn: isOwn,
            isAdmin: isAdmin,
          ),
      ],
    );
  }

  Widget _buildPostMoreMenu({
    required bool isDark,
    required bool canEdit,
    required bool canDelete,
    required bool isOwn,
    required bool isAdmin,
  }) {
    final entries = _buildPostMenuEntries(
      isOwn: isOwn,
      isAdmin: isAdmin,
    );

    return AppActionPopupMenu(
      width: 188,
      offset: const Offset(0, 8),
      icon: const Icon(Icons.more_horiz_rounded),
      accentColor: isDark ? const Color(0xFF7ED6C5) : const Color(0xFF147C72),
      dangerColor: const Color(0xFFE54848),
      entries: entries,
      onSelected: _handlePostMenuAction,
    );
  }

  void _handlePostMenuAction(String value) {
    switch (value) {
      case 'edit':
        _editPost();
        break;
      case 'mark_sold':
        _markAsSold();
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
      case 'apply_featured':
        _applyFeatured();
        break;
      case 'apply_collaboration':
        _applyCollaboration();
        break;
      case 'submit_revision':
        _submitRevisionProposal();
        break;
      case 'creation_management':
        _openCreationManagement();
        break;
      case 'unfeature':
        _unfeaturePost();
        break;
      case 'section_pin':
        _sectionPinPost();
        break;
      case 'section_unpin':
        _sectionUnpinPost();
        break;
      case 'section_feature':
      case 'section_retry_home_feature':
        _sectionFeaturePost();
        break;
      case 'section_unfeature':
        _sectionUnfeaturePost();
        break;
      case 'moderate_delete':
        _moderateDeletePost();
        break;
      case 'mute_author':
        _muteAuthor();
        break;
    }
  }

  List<Object> _buildPostMenuEntries({
    required bool isOwn,
    required bool isAdmin,
  }) {
    final entries = <Object>[];
    final sectionSlug = _post?.postType ?? '';
    final isWaterPost = _post?.boardId == 1;

    final perm = (isWaterPost && sectionSlug.isNotEmpty)
        ? context.read<WaterModeratorProvider>().permissionOf(sectionSlug)
        : null;

    final hasModeration = isWaterPost &&
        sectionSlug.isNotEmpty &&
        perm != null &&
        (perm.isGlobalAdmin || perm.isModerator);

    if (hasModeration) {
      if (perm.canPinPost) {
        entries.add(
          AppPopupAction(
            value: _post?.waterSectionPinned == true
                ? 'section_unpin'
                : 'section_pin',
            label: _post?.waterSectionPinned == true ? '取消版块置顶' : '设为版块置顶',
            icon: _post?.waterSectionPinned == true
                ? Icons.push_pin_outlined
                : Icons.push_pin_rounded,
          ),
        );

        if (_post?.waterSectionFeatured == true) {
          if (_post?.homeFeaturedPending == false &&
              _post?.isFeatured != true) {
            entries.add(
              const AppPopupAction(
                value: 'section_retry_home_feature',
                label: '重试首页推荐',
                icon: Icons.campaign_outlined,
              ),
            );
          }
          entries.add(
            const AppPopupAction(
              value: 'section_unfeature',
              label: '取消版块精华',
              icon: Icons.star_border_rounded,
            ),
          );
        } else {
          entries.add(
            const AppPopupAction(
              value: 'section_feature',
              label: '设为版块精华',
              icon: Icons.auto_awesome_rounded,
            ),
          );
        }
      }

      if (perm.canDeletePost) {
        entries.add(
          const AppPopupAction(
            value: 'moderate_delete',
            label: '版主删除',
            icon: Icons.admin_panel_settings_outlined,
            danger: true,
          ),
        );
      }

      if (perm.canMuteUser && _post?.authorId != null) {
        final currentUserId = context.read<AuthProvider>().user?.id;
        if (currentUserId != _post!.authorId) {
          entries.add(
            const AppPopupAction(
              value: 'mute_author',
              label: '禁言作者',
              icon: Icons.volume_off_outlined,
            ),
          );
        }
      }

      entries.add(const Divider());
    }

    if (isAdmin && _post?.boardId == 1) {
      entries.add(
        AppPopupAction(
          value: _post!.isActivePinned ? 'unpin' : 'pin',
          label: _post!.isActivePinned ? '取消首页置顶' : '置顶到首页',
          icon: _post!.isActivePinned
              ? Icons.vertical_align_top_outlined
              : Icons.home_filled,
        ),
      );
    }

    if (_post?.boardId == 1) {
      if (_post?.isFeatured == true) {
        if (isOwn) {
          entries.add(
            const AppPopupAction(
              value: 'creation_management',
              label: '创作管理',
              icon: Icons.manage_accounts_outlined,
            ),
          );
        } else {
          entries.add(
            const AppPopupAction(
              value: 'apply_collaboration',
              label: '申请共同创作',
              icon: Icons.group_add_outlined,
            ),
          );
          entries.add(
            const AppPopupAction(
              value: 'submit_revision',
              label: '提交修改版本',
              icon: Icons.edit_note_rounded,
            ),
          );
        }
      } else if (_hasPendingFeaturedApp) {
        entries.add(
          const AppPopupAction(
            value: 'pending_featured',
            label: '精华申请待审核',
            icon: Icons.hourglass_top_rounded,
            enabled: false,
          ),
        );
      } else {
        entries.add(
          const AppPopupAction(
            value: 'apply_featured',
            label: '申请精华',
            icon: Icons.star_outline_rounded,
          ),
        );
      }
    }

    entries.add(const Divider());

    if (isOwn) {
      entries.add(
        const AppPopupAction(
          value: 'edit',
          label: '编辑帖子',
          icon: Icons.edit_outlined,
        ),
      );

      if (_canMarkSellPostSold()) {
        entries.add(
          const AppPopupAction(
            value: 'mark_sold',
            label: '标记已售出',
            icon: Icons.check_circle_outline_rounded,
          ),
        );
      }

      entries.add(
        const AppPopupAction(
          value: 'delete',
          label: '删除帖子',
          icon: Icons.delete_outline_rounded,
          danger: true,
        ),
      );
    } else {
      if (isAdmin) {
        entries.add(
          const AppPopupAction(
            value: 'delete',
            label: '删除帖子',
            icon: Icons.delete_outline_rounded,
            danger: true,
          ),
        );

        if (_post?.isFeatured == true) {
          entries.add(
            const AppPopupAction(
              value: 'unfeature',
              label: '取消首页精华',
              icon: Icons.star_border_rounded,
            ),
          );
        }
      }

      entries.add(
        const AppPopupAction(
          value: 'report',
          label: '举报帖子',
          icon: Icons.flag_outlined,
        ),
      );
    }

    while (entries.isNotEmpty && entries.last is Divider) {
      entries.removeLast();
    }

    return entries;
  }

  Widget _buildWaterAppBarCategoryChip(bool isDark) {
    final sectionSlug = _post?.postType ?? '';
    final sectionProvider = context.watch<WaterSectionProvider?>();
    final section =
        sectionSlug.isNotEmpty ? sectionProvider?.getBySlug(sectionSlug) : null;
    final label = section?.title ?? waterCategoryOf(sectionSlug)?.label ?? '水帖';
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _openWaterCategoryFromDetail,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color:
                  isDark ? Colors.white.withValues(alpha: 0.8) : Colors.black87,
            ),
          ),
          const SizedBox(width: 2),
          Icon(
            Icons.chevron_right,
            size: 16,
            color:
                isDark ? Colors.white.withValues(alpha: 0.5) : Colors.black54,
          ),
        ],
      ),
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
                  child: _buildInputDismissRegion(
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
                                    p.price.truncateToDouble() == p.price
                                        ? 0
                                        : 2,
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
                          if (p.marketTags.isNotEmpty) ...[
                            _buildMarketTagWrap(p.marketTags, isDark),
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
                          _buildMarketSellerRow(p, isDark),
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
            child: _buildInputDismissRegion(
              child: p.images.isNotEmpty
                  ? _buildMarketHeroImage(p, isDark, forceFitHeight: true)
                  : Container(
                      color: isDark
                          ? const Color(0xFF131720)
                          : kCleanWarmBackgroundLight,
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
                                color:
                                    isDark ? Colors.white38 : Colors.grey[500],
                                fontSize: 16,
                              ),
                            ),
                          ],
                        ),
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
          child: _buildInputDismissRegion(
            child: SingleChildScrollView(
              padding: const EdgeInsets.only(bottom: 80),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (p.images.isNotEmpty)
                    _buildMarketHeroImage(p, isDark)
                  else
                    SizedBox(
                      height:
                          MediaQuery.of(context).padding.top + kToolbarHeight,
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
                                    p.price.truncateToDouble() == p.price
                                        ? 0
                                        : 2,
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
                          if (p.marketTags.isNotEmpty) ...[
                            _buildMarketTagWrap(p.marketTags, isDark),
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
                          _buildMarketSellerRow(p, isDark),
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
        ),
        _buildReplyBar(isDark),
      ],
    );
  }

  Widget _buildMarketTagWrap(List<String> tags, bool isDark) {
    final primary = Theme.of(context).colorScheme.primary;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: tags
          .map(
            (tag) => Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: isDark
                    ? primary.withValues(alpha: 0.14)
                    : primary.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: primary.withValues(alpha: isDark ? 0.24 : 0.16),
                ),
              ),
              child: Text(
                tag,
                style: TextStyle(
                  fontSize: 13,
                  color: primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          )
          .toList(growable: false),
    );
  }

  Widget _buildMarketHeroImage(
    Post p,
    bool isDark, {
    bool forceFitHeight = false,
  }) {
    return PostMediaView(
      images: p.images,
      variant: PostMediaVariant.detail,
    );
    /*
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
              onLongPress: () => _showImageFavoriteAction(urls[index]),
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
    */
  }

  // ===================================================================
  // 水帖详情布局（全新重构）
  // ===================================================================

  Widget _buildWaterDetail(bool isDark) {
    final p = _post!;
    return SingleChildScrollView(
      key: const ValueKey('post-detail-scroll-view'),
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
                  const SizedBox(height: 8),
                  _buildWaterPostBody(p, isDark),
                ],
                if (p.images.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  _buildAdaptiveWaterImages(p, isDark),
                ],
                const SizedBox(height: 6),
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
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          p.author?.nickname ?? '匿名',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                            color: isDark ? Colors.white : Colors.black87,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (p.author != null) ...[
                        const SizedBox(width: 6),
                        _buildLevelBadge(p.author!, isDark),
                      ],
                      if (p.waterSectionAuthorMeta != null) ...[
                        const SizedBox(width: 6),
                        _buildSectionLevelBadge(p.waterSectionAuthorMeta!),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${_formatTime(p.createdAt)} · 诚信${p.author?.creditScore ?? 100}%',
                    style: TextStyle(
                      fontSize: 11,
                      color: isDark ? Colors.white38 : const Color(0xFF9AA0A6),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${p.viewCount}阅读',
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 11.5,
                color: isDark ? Colors.white54 : const Color(0xFF60646C),
              ),
            ),
          ],
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
          _buildWaterSectionTagInfo(p, isDark),
          if (p.title.isNotEmpty) ...[
            Text(
              p.title,
              style: TextStyle(
                fontSize: 18.5,
                fontWeight: FontWeight.w700,
                height: 1.25,
                color: isDark ? Colors.white : Colors.black87,
              ),
            ),
            const SizedBox(height: 6),
          ],
          if (p.content.isNotEmpty)
            SelectionContainer.disabled(
              child: Text(
                p.content,
                style: TextStyle(
                  fontSize: 14.5,
                  height: 1.55,
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.82)
                      : const Color(0xFF333333),
                ),
              ),
            ),
          if (p.topics.isNotEmpty) ...[
            const SizedBox(height: 8),
            PostTopicChips(topics: p.topics, maxTopics: 5),
          ],
        ],
      ),
    );
  }

  Widget _buildWaterSectionTagInfo(Post p, bool isDark) {
    if (p.boardId != 1 || p.postType.isEmpty) {
      return const SizedBox.shrink();
    }
    final provider = context.watch<WaterSectionProvider>();
    final section = provider.getBySlug(p.postType);
    final sectionLabel = section?.title ?? waterCategoryLabelOf(p.postType);
    final tag = p.topics.isEmpty ? _findWaterTag(section, p.waterTagId) : null;
    if (sectionLabel.isEmpty && tag == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          if (sectionLabel.isNotEmpty)
            _buildWaterMetaPill(
              isDark,
              Icons.forum_outlined,
              '版块：$sectionLabel',
            ),
          if (tag != null)
            _buildWaterMetaPill(
              isDark,
              Icons.sell_outlined,
              '标签：${tag.name}',
            ),
        ],
      ),
    );
  }

  WaterSectionTag? _findWaterTag(WaterSection? section, int? tagId) {
    if (section == null || tagId == null || tagId <= 0) return null;
    for (final tag in section.tags) {
      if (tag.id == tagId &&
          !_ignoredLegacyWaterTagNames.contains(tag.name.trim())) {
        return tag;
      }
    }
    return null;
  }

  Widget _buildWaterMetaPill(bool isDark, IconData icon, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.08)
            : const Color(0xFFF3F4F6),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 12,
            color: isDark ? Colors.white54 : const Color(0xFF60646C),
          ),
          const SizedBox(width: 4),
          Text(
            text,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: isDark ? Colors.white60 : const Color(0xFF60646C),
            ),
          ),
        ],
      ),
    );
  }

  // ---- 自适应图片布局 ----

  Widget _buildAdaptiveWaterImages(Post p, bool isDark) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: PostMediaView(
        images: p.images,
        variant: PostMediaVariant.detail,
      ),
    );
  }

  /*
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
      onLongPress: () => _showImageFavoriteAction(url),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: CachedNetworkImage(
          cacheManager: PostImageCache.manager,
          imageUrl: url,
          width: double.infinity,
          fit: BoxFit.fitWidth,
          placeholder: (_, __) => Container(
            height: 220,
            color: isDark ? Colors.white10 : const Color(0xFFF0F1F3),
          ),
          errorWidget: (_, __, ___) => Container(
            height: 220,
            color: isDark ? Colors.white10 : const Color(0xFFF0F1F3),
            child: const Icon(
              Icons.broken_image,
              size: 40,
              color: Colors.grey,
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
              onLongPress: () => _showImageFavoriteAction(url),
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
            onLongPress: () => _showImageFavoriteAction(urls[index]),
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
  */

  // ---- 水帖操作栏 ----

  Widget _buildWaterActionBar(bool isDark) {
    return Container(
      height: 42,
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
                  _post?.isLiked == true
                      ? Icons.thumb_up
                      : Icons.thumb_up_outlined,
                  size: 16,
                  color: _post?.isLiked == true
                      ? Theme.of(context).primaryColor
                      : (isDark ? Colors.white38 : Colors.grey[500]),
                ),
                const SizedBox(width: 4),
                Text(
                  '${_post?.likeCount ?? 0}',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: _post?.isLiked == true
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
                  size: 16,
                  color: isDark ? Colors.white38 : Colors.grey[500],
                ),
                const SizedBox(width: 4),
                Text(
                  '评论 ${_post?.replyCount ?? 0}',
                  style: TextStyle(
                    fontSize: 11.5,
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
            size: 14,
            color: isDark ? Colors.white24 : Colors.grey[400],
          ),
          const SizedBox(width: 3),
          Text(
            '浏览 ${_post?.viewCount ?? 0}',
            style: TextStyle(
              fontSize: 11,
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
          child: Row(
            children: [
              Text(
                '评论 ${_post?.replyCount ?? _replies.length}',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.white : Colors.black87,
                ),
              ),
              const Spacer(),
              _buildReplySortSelector(isDark),
            ],
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

  Widget _buildComposerBody(bool isDark) {
    return PostReplyComposer(
      controller: _replyComposerController,
      sending: _isSending,
      enabled: context.watch<AuthProvider>().isLoggedIn,
      onSubmit: _sendReplyDraft,
      onNeedLogin: _openReplyLogin,
    );
    /*
    final viewInsets = MediaQuery.viewInsetsOf(context);
    final bottomPadding = _showReplyEmojiPanel ? 0.0 : viewInsets.bottom;

    return AnimatedPadding(
      padding: EdgeInsets.only(bottom: bottomPadding),
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      child: Container(
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF131720) : Colors.white,
          border: Border(
            top: BorderSide(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.08)
                  : const Color(0xFFEDEDED),
              width: 0.5,
            ),
          ),
        ),
        child: SafeArea(
          top: false,
          bottom: bottomPadding == 0,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_selectedReplySticker != null)
                StickerComposerPreview(
                  sticker: _selectedReplySticker!,
                  onRemove: _removeSelectedReplySticker,
                  enabled: !_isSending,
                ),
              if (_selectedReplyFavoriteImage != null)
                FavoriteImageComposerPreview(
                  favorite: _selectedReplyFavoriteImage!,
                  onRemove: _removeSelectedReplyFavoriteImage,
                  enabled: !_isSending,
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: Container(
                        constraints: const BoxConstraints(minHeight: 44),
                        decoration: BoxDecoration(
                          color: isDark
                              ? Colors.white.withValues(alpha: 0.08)
                              : const Color(0xFFF3F4F6),
                          borderRadius: BorderRadius.circular(22),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Expanded(
                              child: TextField(
                                key: const ValueKey('post-reply-input'),
                                controller: _replyController,
                                focusNode: _replyFocus,
                                enabled: !_isSending,
                                readOnly: _isSending,
                                onTap: () {
                                  if (_showReplyEmojiPanel) {
                                    setState(
                                      () => _showReplyEmojiPanel = false,
                                    );
                                  }
                                },
                                minLines: 1,
                                maxLines: 4,
                                textAlignVertical: TextAlignVertical.center,
                                textInputAction: TextInputAction.newline,
                                decoration: InputDecoration(
                                  constraints:
                                      const BoxConstraints(minHeight: 44),
                                  hintText: _replyToName != null
                                      ? '回复 @$_replyToName'
                                      : '写下你的想法...',
                                  hintStyle: TextStyle(
                                    color: isDark
                                        ? Colors.white30
                                        : Colors.grey[400],
                                    fontSize: 14,
                                  ),
                                  border: InputBorder.none,
                                  isDense: true,
                                  contentPadding: const EdgeInsets.fromLTRB(
                                    14,
                                    13,
                                    4,
                                    9,
                                  ),
                                ),
                                style: TextStyle(
                                  fontSize: 14,
                                  color: isDark
                                      ? Colors.white
                                      : const Color(0xFF22242A),
                                  height: 1.3,
                                ),
                              ),
                            ),
                            SizedBox(
                              width: 42,
                              height: 44,
                              child: IconButton(
                                key: const ValueKey(
                                  'post-reply-emoji-button',
                                ),
                                tooltip: _showReplyEmojiPanel ? '打开键盘' : '选择表情',
                                onPressed:
                                    _isSending ? null : _toggleReplyEmojiPanel,
                                padding: EdgeInsets.zero,
                                icon: Icon(
                                  _showReplyEmojiPanel
                                      ? Icons.keyboard_alt_outlined
                                      : Icons.sentiment_satisfied_alt_outlined,
                                  size: 22,
                                  color: isDark
                                      ? Colors.white60
                                      : const Color(0xFF60646C),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ValueListenableBuilder<TextEditingValue>(
                      valueListenable: _replyController,
                      builder: (context, value, _) {
                        final canSend = !_isSending &&
                            (value.text.trim().isNotEmpty ||
                                _selectedReplySticker != null ||
                                _selectedReplyFavoriteImage != null);
                        return IconButton.filled(
                          key: const ValueKey('post-reply-send-button'),
                          tooltip: '发送评论',
                          onPressed: canSend ? _sendReply : null,
                          style: IconButton.styleFrom(
                            fixedSize: const Size(44, 44),
                            backgroundColor: isDark
                                ? const Color(0xFF82A0FF)
                                : const Color(0xFF6B8EFF),
                            foregroundColor: Colors.white,
                            disabledBackgroundColor: isDark
                                ? Colors.white.withValues(alpha: 0.10)
                                : const Color(0xFFE5E7EB),
                            disabledForegroundColor: isDark
                                ? Colors.white30
                                : const Color(0xFF9CA3AF),
                          ),
                          icon: _isSending
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.5,
                                    color: Colors.white,
                                  ),
                                )
                              : const Icon(Icons.send_rounded, size: 20),
                        );
                      },
                    ),
                  ],
                ),
              ),
              AnimatedSize(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOutCubic,
                child: _showReplyEmojiPanel
                    ? SizedBox(
                        height: _replyEmojiPanelHeight,
                        child: AppEmojiPanel(
                          onEmojiSelected: _insertReplyEmoji,
                          onStickerSelected: _selectReplySticker,
                          onFavoriteImageSelected: _selectReplyFavoriteImage,
                          onBackspace: () =>
                              deletePreviousCharacter(_replyController),
                          enabled: !_isSending,
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            ],
          ),
        ),
      ),
    );
    */
  }

  Widget _buildWaterReplyBar(bool isDark) {
    return _buildComposerBody(isDark);
    /*
    if (_isReplyComposerOpen) {
      return _buildComposerBody(isDark);
    }

    // 折叠状态：说点什么… 入口
    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF131720) : Colors.white,
        border: Border(
          top: BorderSide(
            color: isDark
                ? Colors.white.withValues(alpha: 0.08)
                : const Color(0xFFEDEDED),
            width: 0.5,
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
          child: Row(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: () => _openReplyComposer(),
                  child: Container(
                    height: 38,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    decoration: BoxDecoration(
                      color: isDark
                          ? Colors.white.withValues(alpha: 0.08)
                          : const Color(0xFFF3F4F6),
                      borderRadius: BorderRadius.circular(19),
                    ),
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '写下你的想法...',
                      style: TextStyle(
                        fontSize: 14,
                        color: isDark ? Colors.white30 : Colors.grey[400],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              _buildBottomStat(
                icon: Icons.chat_bubble_outline_rounded,
                label: '${_post?.replyCount ?? _replies.length}',
                color: isDark ? Colors.white54 : const Color(0xFF60646C),
                onTap: _openReplyComposer,
              ),
              const SizedBox(width: 10),
              _buildBottomStat(
                icon: _liked ? Icons.thumb_up : Icons.thumb_up_outlined,
                label: '$_likeCount',
                color: _liked
                    ? const Color(0xFFFF6B6B)
                    : (isDark ? Colors.white54 : const Color(0xFF60646C)),
                onTap: _toggleLike,
              ),
            ],
          ),
        ),
      ),
    );
    */
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
                      if (p.waterSectionAuthorMeta != null) ...[
                        const SizedBox(width: 6),
                        _buildSectionLevelBadge(p.waterSectionAuthorMeta!),
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
    AppNavigation.openUserHome(context, userId: userId);
  }

  // ---- 操作栏（集市复用，保持不变） ----

  Widget _buildActionBar(bool isDark) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceAround,
      children: [
        _buildActionButton(
          icon:
              _post?.isLiked == true ? Icons.thumb_up : Icons.thumb_up_outlined,
          color: _post?.isLiked == true
              ? const Color(0xFFFF6B6B)
              : (isDark ? Colors.white38 : Colors.grey.shade500),
          label: '${_post?.likeCount ?? 0}',
          onTap: _toggleLike,
        ),
        _buildActionButton(
          icon: Icons.chat_bubble_outline,
          color: isDark ? Colors.white38 : Colors.grey.shade500,
          label: '${_totalReplies > 0 ? _totalReplies : _replies.length}',
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

  Widget _buildMarketSellerRow(Post post, bool isDark) {
    final contact = post.contact.trim();
    final contactLabel = marketContactTypeLabel(post.contactType);
    final sellerName = post.author?.nickname.trim().isNotEmpty == true
        ? post.author!.nickname.trim()
        : '卖家';

    return Container(
      key: const ValueKey('market-seller-row'),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF222731) : const Color(0xFFF8F9FA),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.06)
              : Colors.black.withValues(alpha: 0.05),
        ),
      ),
      child: Row(
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: post.author == null
                ? null
                : () => _openAuthorHome(post.author!.id),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                CachedAvatar(
                  radius: 20,
                  imageUrl: post.author?.avatar.isNotEmpty == true
                      ? ApiConstants.fullUrl(post.author!.avatar)
                      : null,
                  fallbackText: sellerName,
                ),
                const SizedBox(width: 10),
              ],
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  sellerName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: isDark ? Colors.white : Colors.black87,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '诚信 ${post.author?.creditScore ?? 100}% · ${_formatTime(post.createdAt)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: isDark ? Colors.white54 : Colors.grey[600],
                  ),
                ),
              ],
            ),
          ),
          if (contact.isNotEmpty) ...[
            const SizedBox(width: 8),
            TextButton.icon(
              key: const ValueKey('market-contact-copy'),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: contact));
                if (!mounted) return;
                AppFeedback.showSnackBar(
                  context,
                  marketContactCopiedMessage(post.contactType),
                );
              },
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              icon: Icon(marketContactTypeIcon(post.contactType), size: 16),
              label: Text(
                '$contactLabel · 复制',
                maxLines: 1,
                overflow: TextOverflow.fade,
                softWrap: false,
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ---- 评论区 ----

  /// 评论排序选择器：热门 / 最新。
  Widget _buildReplySortSelector(bool isDark) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _showReplySortSheet(isDark),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: Row(
          key: const ValueKey('reply-sort-selector'),
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_isRepliesLoading) ...[
              SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                  strokeWidth: 1.6,
                  color: isDark ? Colors.white38 : Colors.grey[500],
                ),
              ),
              const SizedBox(width: 6),
            ],
            Text(
              _replySort == 'hot' ? '热门' : '最新',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: isDark ? Colors.white54 : Colors.grey[600],
              ),
            ),
            const SizedBox(width: 2),
            Icon(
              Icons.arrow_drop_down,
              size: 18,
              color: isDark ? Colors.white38 : Colors.grey[500],
            ),
          ],
        ),
      ),
    );
  }

  void _showReplySortSheet(bool isDark) {
    showModalBottomSheet<void>(
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
                Icons.whatshot_outlined,
                color: _replySort == 'hot'
                    ? Theme.of(ctx).primaryColor
                    : (isDark ? Colors.white54 : Colors.grey[500]),
              ),
              title: Text(
                '热门',
                style: TextStyle(
                  color: _replySort == 'hot'
                      ? Theme.of(ctx).primaryColor
                      : (isDark ? Colors.white70 : Colors.black87),
                  fontWeight:
                      _replySort == 'hot' ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
              trailing: _replySort == 'hot'
                  ? Icon(Icons.check,
                      size: 18, color: Theme.of(ctx).primaryColor)
                  : null,
              onTap: () {
                Navigator.pop(ctx);
                _changeReplySort('hot');
              },
            ),
            ListTile(
              leading: Icon(
                Icons.schedule,
                color: _replySort == 'latest'
                    ? Theme.of(ctx).primaryColor
                    : (isDark ? Colors.white54 : Colors.grey[500]),
              ),
              title: Text(
                '最新',
                style: TextStyle(
                  color: _replySort == 'latest'
                      ? Theme.of(ctx).primaryColor
                      : (isDark ? Colors.white70 : Colors.black87),
                  fontWeight: _replySort == 'latest'
                      ? FontWeight.w600
                      : FontWeight.w400,
                ),
              ),
              trailing: _replySort == 'latest'
                  ? Icon(Icons.check,
                      size: 18, color: Theme.of(ctx).primaryColor)
                  : null,
              onTap: () {
                Navigator.pop(ctx);
                _changeReplySort('latest');
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _buildCommentsHeader(bool isDark) {
    final total = _totalReplies > 0 ? _totalReplies : _replies.length;
    return Row(
      children: [
        Icon(
          Icons.forum_outlined,
          size: 18,
          color: isDark ? Colors.white30 : Colors.grey[500],
        ),
        const SizedBox(width: 8),
        Text(
          '全部评论 $total',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: isDark ? Colors.white38 : Colors.grey[500],
          ),
        ),
        const Spacer(),
        _buildReplySortSelector(isDark),
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
      children: [
        ...threads.map(
          (t) => _buildReplyThread(t, isDark, compact: false, depth: 0),
        ),
        if (_repliesHasMore) _buildLoadMoreRepliesButton(isDark),
      ],
    );
  }

  Widget _buildLoadMoreRepliesButton(bool isDark) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Center(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _loadingMoreReplies
              ? null
              : () => _loadReplies(sort: _replySort, loadMore: true),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: isDark ? Colors.white12 : Colors.grey.shade300,
              ),
            ),
            child: _loadingMoreReplies
                ? SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: isDark ? Colors.white38 : Colors.grey[500],
                    ),
                  )
                : Text(
                    '加载更多评论',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: isDark ? Colors.white54 : Colors.grey[600],
                    ),
                  ),
          ),
        ),
      ),
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
    final allChildren = _collectThreadChildren(thread.parent.id);
    // 服务端 child_reply_count 是真实总数（列表只携带前 N 条，其余懒加载）。
    final totalChildren = thread.parent.childReplyCount > 0
        ? thread.parent.childReplyCount
        : allChildren.length;
    final targetChild = _activeTargetReplyId == null
        ? null
        : allChildren
            .where((reply) => reply.id == _activeTargetReplyId)
            .firstOrNull;
    final visibleChildren =
        targetChild != null ? [targetChild] : allChildren.take(1).toList();
    final hasMore = totalChildren > visibleChildren.length;

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 主评论
          _buildMainReply(thread.parent, isDark),
          // 子回复区域（摘要展示）
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
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _showReplyThreadSheet(
                        parentReply: thread.parent,
                        anchorReply: null,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.only(top: 6, bottom: 2),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '共 $totalChildren 条回复 ',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                                color: Theme.of(context).primaryColor,
                              ),
                            ),
                            Icon(
                              Icons.chevron_right_rounded,
                              size: 14,
                              color: Theme.of(context).primaryColor,
                            ),
                          ],
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

  List<Reply> _collectThreadChildren(int rootId) {
    final result = <Reply>[];

    void collect(int parentId) {
      final children = _replies
          .where((r) => r.parentReplyId == parentId)
          .toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

      for (final child in children) {
        result.add(child);
        collect(child.id);
      }
    }

    collect(rootId);
    return result;
  }

  /// 主评论（顶级）
  Widget _buildMainReply(Reply r, bool isDark) {
    if (r.isDeleted) {
      // tombstone：已删除的根评论保留其下讨论，但主体显示删除占位。
      return _buildDeletedReplyRow(isDark);
    }
    final currentUser = context.read<AuthProvider>().user;
    final isOwn = currentUser?.id == r.authorId;
    return _buildReplyAnchor(
      reply: r,
      isDark: isDark,
      child: PostReplyItem(
        reply: r,
        onReply: () => _openReplyComposer(
          parentReplyId: r.id,
          replyToName: r.author?.nickname,
          replyToUserId: r.authorId,
        ),
        onAuthorTap:
            r.author == null ? null : () => _openAuthorHome(r.author!.id),
        onLongPress: () => _showReplyActionSheet(r, isOwn, isDark),
        onMore: () => showReportSheet(
          context,
          targetId: r.id,
          targetType: 'reply',
        ),
        onStickerLongPress: _showStickerFavoriteAction,
        onImageLongPress: _showImageFavoriteAction,
        onLike: () => _toggleReplyLike(r),
        likePending: _pendingReplyLikeTargets.containsKey(r.id),
      ),
    );
  }

  /// 已删除根评论的占位行（保留子讨论的 tombstone 视图）。
  Widget _buildDeletedReplyRow(bool isDark) {
    final muted = isDark ? Colors.white38 : Colors.grey[500];
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isDark
                  ? Colors.white.withValues(alpha: 0.06)
                  : Colors.grey[200],
            ),
            child: Icon(Icons.person_off_outlined, size: 18, color: muted),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '该评论已删除',
                style: TextStyle(
                  fontSize: 13,
                  color: muted,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChildReply(Reply r, bool isDark, {int depth = 0}) {
    final threadParentId = _findTopLevelParentId(r);
    final currentUser = context.read<AuthProvider>().user;
    final isOwn = currentUser?.id == r.authorId;
    return _buildReplyAnchor(
      reply: r,
      isDark: isDark,
      child: Padding(
        padding: EdgeInsets.only(bottom: 6, left: depth * 4.0),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            final parent = _replies.firstWhere(
              (rp) => rp.id == threadParentId,
              orElse: () => r,
            );
            _showReplyThreadSheet(
              parentReply: parent,
              anchorReply: r,
            );
          },
          onLongPress: () => _showReplyActionSheet(r, isOwn, isDark),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF1F222A) : const Color(0xFFF7F8FA),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '${r.author?.nickname ?? '匿名'}：',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w400,
                      color: isDark ? Colors.white54 : const Color(0xFF6B7280),
                    ),
                  ),
                  _buildCompactContentSpan(r, isDark),
                ],
              ),
              style: const TextStyle(height: 1.35),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ),
    );
  }

  InlineSpan _buildCompactContentSpan(Reply r, bool isDark) {
    if (r.hasSticker) {
      return TextSpan(
        text: r.hasTextContent ? '${r.content} [表情]' : '[表情]',
        style: TextStyle(
          fontSize: 12.5,
          color: isDark ? Colors.white60 : const Color(0xFF4B5563),
        ),
      );
    }
    final content = r.content;
    final atRegex = RegExp(r'^@(\S+)\s');
    final match = atRegex.firstMatch(content);
    if (match != null) {
      final atName = match.group(1)!;
      final rest = content.substring(match.end);
      return TextSpan(
        children: [
          TextSpan(
            text: '@$atName ',
            style: TextStyle(
              fontSize: 12.5,
              color: Theme.of(context).primaryColor,
              fontWeight: FontWeight.w500,
            ),
          ),
          TextSpan(
            text: rest,
            style: TextStyle(
              fontSize: 12.5,
              color: isDark ? Colors.white60 : const Color(0xFF4B5563),
            ),
          ),
        ],
      );
    }
    return TextSpan(
      text: content,
      style: TextStyle(
        fontSize: 12.5,
        color: isDark ? Colors.white60 : const Color(0xFF4B5563),
      ),
    );
  }

  Future<void> _showReplyThreadSheet({
    required Reply parentReply,
    required Reply? anchorReply,
  }) async {
    _replyComposerController.close();

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final threadComposerController = PostReplyComposerController();
    final initialTarget = anchorReply ?? parentReply;
    threadComposerController.setReplyTarget(
      parentReplyId: parentReply.id,
      replyToUserId: initialTarget.authorId,
      replyToReplyId: initialTarget.id,
      replyToName: initialTarget.author?.nickname,
    );
    var isSending = false;

    // 楼中楼 sheet 的子回复快照：初始取已在列表中的数据，剩余懒加载。
    // 深链锚定（anchorReply 为子回复）时跳过列表预览，首屏直接加载以目标
    // 结尾的窗口页（before_reply_id），并在窗口中高亮目标。
    final anchored = anchorReply != null;
    final sheetChildren = <Reply>[
      if (!anchored) ..._collectThreadChildren(parentReply.id),
    ];
    var childrenTotal = parentReply.childReplyCount > 0
        ? parentReply.childReplyCount
        : sheetChildren.length;
    if (anchored && childrenTotal == 0) childrenTotal = 1;
    String? sheetChildrenCursor;
    // loading 只表示"请求在途"；"还需要继续加载"由 hasMoreChildren 单独判断。
    // 之前用 needsLoad 初始化 loading 会在 loadMoreChildren 入口被自身挡住，
    // 导致首轮请求永远不发（死锁）。
    bool sheetChildrenLoading = false;
    bool sheetChildrenError = false;
    bool firstChildrenRequest = true;
    VoidCallback? sheetUpdater;

    Future<void> loadMoreChildren() async {
      if (sheetChildrenLoading) return;
      sheetChildrenLoading = true;
      sheetChildrenError = false;
      sheetUpdater?.call();
      try {
        final resp = await _dio.get(
          '/posts/${widget.postId}/replies/${parentReply.id}/children',
          queryParameters: {
            'limit': 50,
            if (anchored && firstChildrenRequest)
              'before_reply_id': anchorReply!.id,
            if (sheetChildrenCursor != null) 'cursor': sheetChildrenCursor,
          },
        );
        firstChildrenRequest = false;
        final data = resp.data;
        if (data is Map<String, dynamic> && data['replies'] is List) {
          final fetched = (data['replies'] as List)
              .map((e) => Reply.fromJson(e as Map<String, dynamic>))
              .toList();
          final known = sheetChildren.map((r) => r.id).toSet();
          sheetChildren.addAll(fetched.where((r) => !known.contains(r.id)));
          final next = data['next_cursor'] as String?;
          sheetChildrenCursor = (next != null && next.isNotEmpty) ? next : null;
          if (sheetChildren.length >= childrenTotal) {
            sheetChildrenCursor = null;
          }
        }
      } on DioException {
        sheetChildrenError = true;
      } catch (_) {
        sheetChildrenError = true;
      } finally {
        sheetChildrenLoading = false;
        sheetUpdater?.call();
      }
    }

    // 打开 sheet 前就开始补拉剩余子回复，避免打开后再闪 loading。
    if (childrenTotal > sheetChildren.length) {
      unawaited(loadMoreChildren());
    }

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.08),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContentContext, setSheetState) {
            sheetUpdater = () {
              if (sheetContentContext.mounted) setSheetState(() {});
            };

            void selectReplyTarget(Reply target) {
              if (target.isDeleted) {
                AppFeedback.showSnackBar(
                  sheetContentContext,
                  '该评论已删除，无法回复',
                  isError: true,
                );
                return;
              }
              final nickname = target.author?.nickname.trim() ?? '';
              threadComposerController.openReply(
                parentReplyId: parentReply.id,
                replyToUserId: target.authorId,
                replyToReplyId: target.id,
                replyToName: nickname,
              );
            }

            return AnimatedBuilder(
              animation: threadComposerController,
              builder: (animContext, _) {
                final isEmoji = threadComposerController.bottomPanel ==
                    PostReplyBottomPanel.emoji;
                final keyboardInset =
                    MediaQuery.viewInsetsOf(sheetContentContext).bottom;
                final bottomPadding = isEmoji ? 0.0 : keyboardInset;

                return AnimatedPadding(
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOutCubic,
                  padding: EdgeInsets.only(bottom: bottomPadding),
                  child: DraggableScrollableSheet(
                    initialChildSize: 0.72,
                    minChildSize: 0.50,
                    maxChildSize: 0.92,
                    expand: false,
                    builder: (context, scrollController) {
                      return Container(
                        decoration: BoxDecoration(
                          color:
                              isDark ? const Color(0xFF171B24) : Colors.white,
                          borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(16),
                          ),
                        ),
                        child: Column(
                          children: [
                            _buildReplyThreadSheetHeader(sheetContext, isDark),
                            Expanded(
                              child: CustomScrollView(
                                controller: scrollController,
                                slivers: [
                                  SliverToBoxAdapter(
                                    child: Padding(
                                      padding: const EdgeInsets.fromLTRB(
                                          16, 12, 16, 16),
                                      child: _buildSheetParentReply(
                                        sheetContext,
                                        parentReply,
                                        isDark,
                                        onReply: () =>
                                            selectReplyTarget(parentReply),
                                      ),
                                    ),
                                  ),
                                  SliverToBoxAdapter(
                                    child: _buildRelatedRepliesHeader(
                                      childrenTotal,
                                      isDark,
                                    ),
                                  ),
                                  SliverPadding(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 16),
                                    sliver: _buildSheetChildrenList(
                                      sheetContext,
                                      sheetChildren,
                                      isDark,
                                      onReply: selectReplyTarget,
                                      loading: sheetChildrenLoading,
                                      error: sheetChildrenError,
                                      hasMore: sheetChildrenCursor != null,
                                      onLoadMore: loadMoreChildren,
                                      highlightReplyId:
                                          anchored ? anchorReply!.id : null,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            PostReplyComposer(
                              controller: threadComposerController,
                              sending: isSending,
                              enabled: context.watch<AuthProvider>().isLoggedIn,
                              preserveReplyTargetOnSuccess: true,
                              onSubmit: (draft) async {
                                if (isSending) return false;
                                setSheetState(() => isSending = true);
                                try {
                                  final created =
                                      await _createReplyFromDraft(draft);
                                  if (created != null) {
                                    if (sheetContentContext.mounted) {
                                      setSheetState(() {
                                        if (!sheetChildren
                                            .any((c) => c.id == created.id)) {
                                          sheetChildren.add(created);
                                          childrenTotal++;
                                        }
                                      });
                                    }
                                    threadComposerController.setReplyTarget(
                                      parentReplyId: parentReply.id,
                                      replyToUserId: parentReply.authorId,
                                      replyToReplyId: parentReply.id,
                                      replyToName: parentReply.author?.nickname,
                                    );
                                    return true;
                                  }
                                  return false;
                                } on DioException catch (error) {
                                  if (sheetContentContext.mounted) {
                                    AppFeedback.showSnackBar(
                                      sheetContentContext,
                                      AppFeedback.dioErrorMessage(error,
                                          fallback: '回复发送失败'),
                                      isError: true,
                                    );
                                  }
                                  return false;
                                } catch (error) {
                                  if (sheetContentContext.mounted) {
                                    AppFeedback.showSnackBar(
                                      sheetContentContext,
                                      '回复发送失败',
                                      isError: true,
                                    );
                                  }
                                  return false;
                                } finally {
                                  if (sheetContentContext.mounted) {
                                    setSheetState(() => isSending = false);
                                  }
                                }
                              },
                              onNeedLogin: _openReplyLogin,
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                );
              },
            );
          },
        );
      },
    );

    threadComposerController.dispose();
  }

  Widget _buildReplyThreadSheetHeader(BuildContext sheetContext, bool isDark) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 10),
        Container(
          width: 36,
          height: 4,
          decoration: BoxDecoration(
            color: isDark ? Colors.white24 : Colors.grey[300],
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const SizedBox(width: 24), // balance close button
              Text(
                '评论详情',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: isDark ? Colors.white : Colors.black87,
                ),
              ),
              GestureDetector(
                onTap: () => Navigator.pop(sheetContext),
                // 48dp 最小触控目标。
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Icon(
                    Icons.close,
                    size: 24,
                    color: isDark ? Colors.white54 : Colors.grey[600],
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Divider(
          height: 1,
          thickness: 1,
          color: isDark ? Colors.white10 : Colors.grey[200],
        ),
      ],
    );
  }

  Widget _buildSheetParentReply(
    BuildContext sheetContext,
    Reply r,
    bool isDark, {
    required VoidCallback onReply,
  }) {
    if (r.isDeleted) {
      // tombstone 根：显示删除占位，不提供回复/点赞/更多入口。
      final muted = isDark ? Colors.white38 : Colors.grey[500];
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isDark
                  ? Colors.white.withValues(alpha: 0.06)
                  : Colors.grey[200],
            ),
            child: Icon(Icons.person_off_outlined, size: 18, color: muted),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '该评论已删除',
                style: TextStyle(
                  fontSize: 13,
                  color: muted,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
          ),
        ],
      );
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onReply,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: () {
              Navigator.pop(sheetContext);
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
                  child: _buildReplyContent(r, isDark),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    GestureDetector(
                      onTap: onReply,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.reply,
                            size: 14,
                            color: isDark ? Colors.white38 : Colors.grey[500],
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '回复',
                            style: TextStyle(
                              fontSize: 12,
                              color: isDark ? Colors.white38 : Colors.grey[500],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Spacer(),
                    _buildSheetReplyLikeButton(r, isDark),
                    GestureDetector(
                      onTap: () {
                        Navigator.pop(sheetContext);
                        showReportSheet(
                          context,
                          targetId: r.id,
                          targetType: 'reply',
                        );
                      },
                      // 48dp 最小触控目标。
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Icon(
                          Icons.more_horiz,
                          size: 16,
                          color: isDark ? Colors.white24 : Colors.grey[300],
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRelatedRepliesHeader(int total, bool isDark) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          height: 8,
          color: isDark ? Colors.black26 : const Color(0xFFF3F4F6),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '相关回复共 $total 条',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.white60 : Colors.grey[700],
                ),
              ),
              Text(
                '按时间',
                style: TextStyle(
                  fontSize: 12,
                  color: isDark ? Colors.white30 : Colors.grey[400],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSheetChildrenList(
    BuildContext sheetContext,
    List<Reply> children,
    bool isDark, {
    required ValueChanged<Reply> onReply,
    required bool loading,
    required bool error,
    required bool hasMore,
    required VoidCallback onLoadMore,
    int? highlightReplyId,
  }) {
    final hasTrailer = loading || error || hasMore;
    if (children.isEmpty && !loading) {
      return const SliverToBoxAdapter(
        child: SizedBox(height: 100),
      );
    }

    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (context, index) {
          if (index < children.length) {
            return _buildSheetChildReplyItem(
              sheetContext,
              children[index],
              isDark,
              onReply: () => onReply(children[index]),
              highlight: children[index].id == highlightReplyId,
            );
          }
          if (loading) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            );
          }
          if (error) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Center(
                child: TextButton(
                  onPressed: onLoadMore,
                  child: Text(
                    '加载失败，点击重试',
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark ? Colors.white54 : Colors.grey[600],
                    ),
                  ),
                ),
              ),
            );
          }
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Center(
              child: TextButton(
                onPressed: onLoadMore,
                child: Text(
                  '加载更多回复',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).primaryColor,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          );
        },
        childCount: children.length + (hasTrailer ? 1 : 0),
      ),
    );
  }

  Widget _buildSheetChildReplyItem(
    BuildContext sheetContext,
    Reply child,
    bool isDark, {
    required VoidCallback onReply,
    bool highlight = false,
  }) {
    final currentUser = context.read<AuthProvider>().user;
    final isOwn = currentUser?.id == child.authorId;
    final isAdmin = currentUser?.isAdmin ?? false;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onReply,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
        padding: highlight
            ? const EdgeInsets.symmetric(horizontal: 8, vertical: 4)
            : EdgeInsets.zero,
        decoration: highlight
            ? BoxDecoration(
                color: Theme.of(context)
                    .primaryColor
                    .withValues(alpha: isDark ? 0.16 : 0.08),
                borderRadius: BorderRadius.circular(10),
              )
            : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GestureDetector(
                onTap: () {
                  Navigator.pop(sheetContext);
                  if (child.author != null) {
                    _openAuthorHome(child.author!.id);
                  }
                },
                child: CachedAvatar(
                  radius: 14,
                  imageUrl: child.author?.avatar.isNotEmpty == true
                      ? ApiConstants.fullUrl(child.author!.avatar)
                      : null,
                  fallbackText: child.author?.nickname,
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
                          child.author?.nickname ?? '匿名',
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w500,
                            color: isDark ? Colors.white70 : Colors.black87,
                          ),
                        ),
                        if (child.author != null) ...[
                          const SizedBox(width: 4),
                          _buildLevelBadgeSmall(child.author!, isDark),
                        ],
                        const SizedBox(width: 8),
                        Text(
                          _formatTime(child.createdAt),
                          style: TextStyle(
                            fontSize: 11,
                            color: isDark ? Colors.white24 : Colors.grey[400],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    _buildChildContent(child, isDark),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        GestureDetector(
                          onTap: onReply,
                          child: Text(
                            '回复',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                              color: isDark ? Colors.white38 : Colors.grey[500],
                            ),
                          ),
                        ),
                        const Spacer(),
                        _buildSheetReplyLikeButton(child, isDark),
                        if (isOwn || isAdmin)
                          GestureDetector(
                            onTap: () async {
                              Navigator.pop(sheetContext);
                              await _deleteReply(child);
                            },
                            child: Text(
                              '删除',
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.red[400],
                              ),
                            ),
                          )
                        else
                          GestureDetector(
                            onTap: () {
                              Navigator.pop(sheetContext);
                              showReportSheet(context,
                                  targetId: child.id, targetType: 'reply');
                            },
                            child: Text(
                              '举报',
                              style: TextStyle(
                                fontSize: 11,
                                color:
                                    isDark ? Colors.white24 : Colors.grey[400],
                              ),
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
      ),
    );
  }

  /// BottomSheet 内的回复点赞按钮：完整线程视图中展示点赞操作。
  Widget _buildSheetReplyLikeButton(Reply r, bool isDark) {
    final pending = _pendingReplyLikeTargets.containsKey(r.id);
    final activeColor = Theme.of(context).primaryColor;
    final idleColor = isDark ? Colors.white38 : Colors.grey[400];
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: pending ? null : () => _toggleReplyLike(r),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              r.isLiked ? Icons.favorite : Icons.favorite_border,
              size: 15,
              color: r.isLiked ? activeColor : idleColor,
            ),
            if (r.likeCount > 0) ...[
              const SizedBox(width: 4),
              Text(
                '${r.likeCount}',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: r.isLiked ? activeColor : idleColor,
                ),
              ),
            ],
          ],
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
    if (r.hasSticker) {
      return SelectionContainer.disabled(
        child: _buildReplyContent(r, isDark, size: 104),
      );
    }
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

  Widget _buildReplyContent(Reply reply, bool isDark, {double size = 132}) {
    final textWidget = Text(
      reply.content,
      style: TextStyle(
        fontSize: 14,
        height: 1.55,
        color: isDark ? Colors.white70 : Colors.grey[800],
      ),
    );
    final contentWidgets = <Widget>[];
    if (reply.hasTextContent) {
      contentWidgets.add(textWidget);
    }
    if (reply.hasSticker) {
      final localSticker = appStickerById(reply.stickerId);
      contentWidgets.add(
        GestureDetector(
          onLongPress: localSticker == null
              ? null
              : () => _showStickerFavoriteAction(localSticker),
          child: CachedNetworkImage(
            key: ValueKey('reply-sticker-${reply.id}'),
            imageUrl: ApiConstants.fullUrl(reply.stickerUrl),
            width: size,
            height: size,
            fit: BoxFit.contain,
            placeholder: (_, __) => localSticker == null
                ? SizedBox(
                    width: size,
                    height: size,
                    child: const Center(
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  )
                : Image.asset(
                    localSticker.thumbnailAsset,
                    width: size,
                    height: size,
                    fit: BoxFit.contain,
                  ),
            errorWidget: (_, __, ___) => localSticker == null
                ? SizedBox(
                    width: size,
                    height: size,
                    child:
                        const Center(child: Icon(Icons.broken_image_outlined)),
                  )
                : Image.asset(
                    localSticker.thumbnailAsset,
                    width: size,
                    height: size,
                    fit: BoxFit.contain,
                  ),
          ),
        ),
      );
    }
    final imageUrls = reply.images
        .map((image) => image.file?.url.trim() ?? '')
        .where((url) => url.isNotEmpty)
        .map(ApiConstants.fullUrl)
        .toList(growable: false);
    if (imageUrls.isNotEmpty) {
      contentWidgets.add(
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: List.generate(imageUrls.length, (index) {
            final imageSize = imageUrls.length == 1 ? size * 1.45 : 88.0;
            return GestureDetector(
              key: ValueKey('reply-image-${reply.id}-$index'),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ImageViewerScreen(
                    imageUrls: imageUrls,
                    initialIndex: index,
                  ),
                ),
              ),
              onLongPress: () => _showImageFavoriteAction(imageUrls[index]),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: CachedNetworkImage(
                  imageUrl: imageUrls[index],
                  width: imageSize,
                  height: imageSize,
                  fit: BoxFit.cover,
                  errorWidget: (_, __, ___) => SizedBox(
                    width: imageSize,
                    height: imageSize,
                    child: const Icon(Icons.broken_image_outlined),
                  ),
                ),
              ),
            );
          }),
        ),
      );
    }
    if (contentWidgets.isEmpty) return textWidget;
    if (contentWidgets.length == 1) return contentWidgets.single;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var index = 0; index < contentWidgets.length; index++) ...[
          if (index > 0) const SizedBox(height: 8),
          contentWidgets[index],
        ],
      ],
    );
  }

  // ---- 回复输入（集市保留） ----

  Widget _buildReplyBar(bool isDark) {
    return _buildComposerBody(isDark);
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
    final post = _post;
    return widget.isMarket &&
        _isCurrentUserPostOwner() &&
        post != null &&
        post.status != 'sold' &&
        post.status != 'closed';
  }

  bool _canMarkSellPostSold() {
    final post = _post;
    return _isCurrentUserPostOwner() &&
        post != null &&
        post.boardId == 2 &&
        post.postType == 'sell' &&
        post.status != 'sold' &&
        post.status != 'closed';
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

  Widget _buildSectionLevelBadge(WaterSectionAuthorMeta meta) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: const Color(0xFF6B8EFF).withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        meta.title,
        style: const TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: Color(0xFF6B8EFF),
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
    int? replyToReplyId,
  }) {
    if (!context.read<AuthProvider>().isLoggedIn) {
      _openReplyLogin();
      return;
    }
    if (parentReplyId != null) {
      _replyComposerController.openReply(
        parentReplyId: parentReplyId,
        replyToName: replyToName,
        replyToUserId: replyToUserId,
        replyToReplyId: replyToReplyId ?? parentReplyId,
      );
      return;
    }
    _replyComposerController.openRoot();
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

  Future<void> _showStickerFavoriteAction(AppSticker sticker) async {
    final service = EmojiFavoriteService.instance;
    final isFavorite = await service.containsSticker(sticker.id);
    if (!mounted) return;
    final shouldToggle = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListTile(
          leading: Icon(
            isFavorite ? Icons.favorite_rounded : Icons.favorite_border_rounded,
          ),
          title: Text(isFavorite ? '取消收藏' : '收藏'),
          onTap: () => Navigator.pop(context, true),
        ),
      ),
    );
    if (shouldToggle != true) return;
    final added = await service.toggleSticker(sticker.id);
    if (mounted) {
      AppFeedback.showSnackBar(
        context,
        added ? '已添加到收藏' : '已取消收藏',
      );
    }
  }

  Future<void> _showImageFavoriteAction(String imageUrl) async {
    final normalizedUrl = imageUrl.trim();
    if (normalizedUrl.isEmpty) return;
    final service = EmojiFavoriteService.instance;
    final isFavorite = await service.containsImage(normalizedUrl);
    if (!mounted) return;
    final shouldToggle = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListTile(
          leading: Icon(
            isFavorite ? Icons.favorite_rounded : Icons.favorite_border_rounded,
          ),
          title: Text(isFavorite ? '取消收藏' : '收藏'),
          onTap: () => Navigator.pop(context, true),
        ),
      ),
    );
    if (shouldToggle != true) return;
    try {
      final added = await service.toggleImage(normalizedUrl);
      if (mounted) {
        AppFeedback.showSnackBar(
          context,
          added ? '已添加到收藏' : '已取消收藏',
        );
      }
    } catch (e) {
      if (mounted) {
        AppFeedback.showSnackBar(context, '收藏操作失败，请检查网络后重试', isError: true);
      }
    }
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
        // 重新拉取：删除根评论可能变成 tombstone，计数以服务端为准。
        _loadReplies();
      }
    } on DioException catch (e) {
      final msg = AppFeedback.dioErrorMessage(e, fallback: '删除失败');
      if (mounted) {
        AppFeedback.showSnackBar(context, msg, isError: true);
      }
    }
  }

  /// 加载回复列表。切换排序只调用此方法，不重新拉帖子详情。
  ///
  /// 根评论游标分页：首屏/切排序 replace，[loadMore] 时按游标追加并按 id 去重。
  /// 受 [_replyRequestVersion] 保护：用户快速切换 Hot/Latest 时，
  /// 后发出的请求版本号更大，先返回的旧响应会被直接丢弃。
  /// 加载完成后，用 [_pendingReplyLikeTargets] 覆盖在途点赞的目标状态，
  /// 避免"♥13 → 切排序 → ♡12 → 请求完成 → ♥13"的闪烁。
  Future<void> _loadReplies({String? sort, bool loadMore = false}) async {
    final effectiveSort = sort ?? _replySort;
    final requestVersion = ++_replyRequestVersion;
    if (mounted) {
      setState(() {
        if (loadMore) {
          _loadingMoreReplies = true;
        } else {
          _isRepliesLoading = true;
        }
      });
    }
    try {
      final repliesResponse = await _dio.get(
        '/posts/${widget.postId}/replies',
        queryParameters: {
          'sort': effectiveSort,
          if (loadMore && _repliesNextCursor != null)
            'cursor': _repliesNextCursor,
        },
      );
      if (!mounted || requestVersion != _replyRequestVersion) return;
      final data = repliesResponse.data;
      if (data is! Map<String, dynamic>) return;
      final rawReplies = data['replies'];
      if (rawReplies is! List) return;
      setState(() {
        var replies = rawReplies
            .map((e) => Reply.fromJson(e as Map<String, dynamic>))
            .toList();
        // 覆盖在途点赞目标，防止服务端旧状态覆盖乐观 UI。
        if (_pendingReplyLikeTargets.isNotEmpty) {
          replies = [
            for (final r in replies)
              _pendingReplyLikeTargets.containsKey(r.id)
                  ? r.copyWith(isLiked: _pendingReplyLikeTargets[r.id])
                  : r,
          ];
        }
        if (loadMore) {
          // 追加并按 id 去重（cursor 找不到时服务端可能从第一页开始重发）。
          final known = _replies.map((r) => r.id).toSet();
          _replies = [
            ..._replies,
            ...replies.where((r) => !known.contains(r.id)),
          ];
        } else {
          _replies = replies;
        }
        _totalReplies = (data['total'] as num?)?.toInt() ?? _replies.length;
        final next = data['next_cursor'] as String?;
        _repliesNextCursor = (next != null && next.isNotEmpty) ? next : null;
        _repliesHasMore = _repliesNextCursor != null;
        // 保持评论数与服务端口径一致（total 含 tombstone 根）。
        if (_post != null) {
          _post = _post!.copyWith(replyCount: _totalReplies);
        }
      });
    } on DioException catch (e) {
      if (!mounted || requestVersion != _replyRequestVersion) return;
      final msg = AppFeedback.dioErrorMessage(e, fallback: '加载回复失败');
      AppFeedback.showSnackBar(context, msg, isError: true);
    } catch (e) {
      if (!mounted || requestVersion != _replyRequestVersion) return;
      AppFeedback.showSnackBar(context, '加载回复失败: $e', isError: true);
    } finally {
      // 统一收口：任何路径（含响应结构异常直接 return）都复位 loading 标志，
      // 避免新旧服务 schema 错配时页面一直转圈。
      if (mounted &&
          requestVersion == _replyRequestVersion &&
          (_isRepliesLoading || _loadingMoreReplies)) {
        setState(() {
          _isRepliesLoading = false;
          _loadingMoreReplies = false;
        });
      }
    }
  }

  /// 切换评论排序（热门/最新）。只刷新回复列表，不重新请求帖子详情。
  Future<void> _changeReplySort(String sort) async {
    if (sort == _replySort) return;
    setState(() {
      _replySort = sort;
    });
    await _loadReplies(sort: sort);
  }

  /// 评论点赞入口：登录检查 → pending 防连点 → optimistic 翻转 →
  /// 请求服务端 → 成功保持 / 失败 rollback / 4xx 冲突重拉列表。
  Future<void> _toggleReplyLike(Reply reply) async {
    if (!context.read<AuthProvider>().isLoggedIn) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请先登录')));
      return;
    }
    if (_pendingReplyLikeTargets.containsKey(reply.id)) return; // 防连点

    final targetLiked = !reply.isLiked;
    final original = reply;
    final optimistic = reply.copyWith(
      isLiked: targetLiked,
      likeCount: (reply.likeCount + (targetLiked ? 1 : -1)).clamp(0, 1 << 30),
    );

    setState(() {
      _pendingReplyLikeTargets[reply.id] = targetLiked;
      _replaceReplyInList(reply.id, optimistic);
    });

    final provider = context.read<PostProvider>();
    final result = targetLiked
        ? await provider.likeReply(reply.id)
        : await provider.unlikeReply(reply.id);
    if (!mounted) return;

    if (result.success) {
      // 保持 optimistic 状态，清除 pending。
      setState(() {
        _pendingReplyLikeTargets.remove(reply.id);
      });
      return;
    }
    if (result.conflict) {
      // 4xx 业务冲突（评论已删除等）：回滚 + 重新拉取，本地列表可能已陈旧。
      setState(() {
        _pendingReplyLikeTargets.remove(reply.id);
        _replaceReplyInList(reply.id, original);
      });
      AppFeedback.showSnackBar(
        context,
        result.errorMessage ?? '操作失败，请稍后重试',
        isError: true,
      );
      _loadReplies();
      return;
    }
    // 网络失败：回滚旧状态。
    setState(() {
      _pendingReplyLikeTargets.remove(reply.id);
      _replaceReplyInList(reply.id, original);
    });
    AppFeedback.showSnackBar(
      context,
      result.errorMessage ?? '点赞失败，请稍后重试',
      isError: true,
    );
  }

  /// 用 replacement 替换 _replies 中同 id 的回复（原地，不重建列表引用）。
  void _replaceReplyInList(int replyId, Reply replacement) {
    final index = _replies.indexWhere((r) => r.id == replyId);
    if (index >= 0) {
      _replies[index] = replacement;
    }
  }
}

/// 楼中楼数据结构（扁平化子回复）
class _ReplyThread {
  final Reply parent;
  final List<Reply> children; // 直接子回复列表，不再递归
  _ReplyThread({required this.parent, required this.children});
}

class _PremiumInputDialog extends StatefulWidget {
  final String title;
  final String hint;
  final String confirmText;

  const _PremiumInputDialog({
    required this.title,
    required this.hint,
    required this.confirmText,
  });

  @override
  State<_PremiumInputDialog> createState() => _PremiumInputDialogState();
}

class _PremiumInputDialogState extends State<_PremiumInputDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final dialogBackground = isDark ? const Color(0xFF1E1E2E) : Colors.white;
    final titleColor = isDark ? Colors.white : const Color(0xFF2D3142);
    final accent = isDark ? const Color(0xFF7ED6C5) : const Color(0xFF147C72);

    return AlertDialog(
      backgroundColor: dialogBackground,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Text(widget.title,
          style: TextStyle(
              color: titleColor, fontSize: 18, fontWeight: FontWeight.bold)),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(
          hintText: widget.hint,
          hintStyle: TextStyle(color: isDark ? Colors.white38 : Colors.black38),
          filled: true,
          fillColor: isDark ? const Color(0x0AFFFFFF) : const Color(0x08000000),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: accent, width: 1.5),
          ),
        ),
        maxLines: 3,
        minLines: 1,
      ),
      actions: [
        TextButton(
          style: TextButton.styleFrom(
              foregroundColor: isDark ? Colors.white54 : Colors.black54),
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: accent,
            foregroundColor: Colors.white,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
          child: Text(widget.confirmText),
        ),
      ],
    );
  }
}

class _PremiumOptionsDialog<T> extends StatelessWidget {
  final String title;
  final List<T> options;
  final String Function(T) labelBuilder;

  const _PremiumOptionsDialog({
    required this.title,
    required this.options,
    required this.labelBuilder,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final dialogBackground = isDark ? const Color(0xFF1E1E2E) : Colors.white;
    final titleColor = isDark ? Colors.white : const Color(0xFF2D3142);
    final tileColor =
        isDark ? const Color(0x0AFFFFFF) : const Color(0x08000000);

    return AlertDialog(
      backgroundColor: dialogBackground,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Text(title,
          style: TextStyle(
              color: titleColor, fontSize: 18, fontWeight: FontWeight.bold)),
      contentPadding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: options.map((opt) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 8.0),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () => Navigator.pop(context, opt),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
                decoration: BoxDecoration(
                  color: tileColor,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text(
                  labelBuilder(opt),
                  style: TextStyle(
                    color: titleColor,
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}
