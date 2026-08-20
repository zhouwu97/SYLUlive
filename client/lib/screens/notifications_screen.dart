import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/theme_provider.dart';
import '../models/startup_destination.dart';
import '../services/root_page_state_service.dart';
import '../utils/app_navigator.dart';
import '../widgets/glass_container.dart';
import '../widgets/cached_avatar.dart';
import '../config/api_constants.dart';
import '../utils/app_feedback.dart';
import '../models/post.dart';
import '../utils/post_route.dart';
import '../services/reply_notification_service.dart';
import '../services/reply_notification_state.dart';

@visibleForTesting
bool canLoadMoreNotifications({
  required bool hasMore,
  required bool isLoading,
  required bool isRefreshing,
  required bool isLoadingMore,
  required String? nextCursor,
}) {
  return hasMore &&
      !isLoading &&
      !isRefreshing &&
      !isLoadingMore &&
      nextCursor != null;
}

class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen>
    with RouteAware {
  PageRoute<dynamic>? _subscribedRoute;
  List<Map<String, dynamic>> _notifications = [];
  final Set<int> _openingNotificationIds = <int>{};
  final ScrollController _scrollController = ScrollController();
  bool _isLoading = true;
  bool _isRefreshing = false;
  bool _isLoadingMore = false;
  bool _hasMore = false;
  String? _nextCursor;
  String? _errorMessage;
  String? _loadMoreError;
  int _requestGeneration = 0;

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
  void didPop() {
    final auth = context.read<AuthProvider>();
    final accountId = auth.user?.id;
    if (auth.isLoggedIn && accountId != null) {
      ReplyNotificationState.instance.requestRefresh(
        accountId: accountId,
        sessionGeneration: auth.sessionGeneration,
      );
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    if (_subscribedRoute != null) {
      appRouteObserver.unsubscribe(this);
    }
    super.dispose();
  }

  /// 仅在 `lastPage` 模式下，把通知中心保存为 lastPage。
  /// 最佳努力：读取失败（如测试用 Fake Provider）时静默跳过，不打断页面。
  void _saveCurrentPageAsLastPage() {
    try {
      final theme = context.read<ThemeProvider>();
      if (theme.startupDestination != StartupDestinationMode.lastPage) return;
      final accountId = context.read<AuthProvider>().user?.id;
      if (accountId == null || accountId <= 0) return;
      unawaited(RootPageStateStore.instance.saveLastPage(
        RestorablePageState(
          type: RestorablePageType.notification,
          arguments: <String, dynamic>{
            'underlyingRootTab': currentHomeTabIndex.value,
          },
          accountId: accountId,
        ),
      ));
    } catch (_) {
      // 忽略：不影响正常浏览。
    }
  }

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _loadReplies();
  }

  void _onScroll() {
    if (!_scrollController.hasClients ||
        !canLoadMoreNotifications(
          hasMore: _hasMore,
          isLoading: _isLoading,
          isRefreshing: _isRefreshing,
          isLoadingMore: _isLoadingMore,
          nextCursor: _nextCursor,
        )) {
      return;
    }
    if (_scrollController.position.extentAfter < 480) {
      unawaited(_loadReplies(loadMore: true));
    }
  }

  int? _notificationId(Map<String, dynamic> notification) {
    final raw = notification['id'];
    if (raw is int) return raw;
    return int.tryParse(raw?.toString() ?? '');
  }

  Future<void> _loadReplies({bool loadMore = false}) async {
    final auth = context.read<AuthProvider>();
    if (!auth.isLoggedIn) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _isRefreshing = false;
          _isLoadingMore = false;
          _notifications = [];
          _nextCursor = null;
          _hasMore = false;
          _errorMessage = null;
        });
      }
      return;
    }

    if (loadMore &&
        !canLoadMoreNotifications(
          hasMore: _hasMore,
          isLoading: _isLoading,
          isRefreshing: _isRefreshing,
          isLoadingMore: _isLoadingMore,
          nextCursor: _nextCursor,
        )) {
      return;
    }

    final accountId = auth.user?.id;
    final sessionGeneration = auth.sessionGeneration;
    if (accountId == null) return;
    final requestGeneration = ++_requestGeneration;

    if (mounted) {
      setState(() {
        if (loadMore) {
          _isLoadingMore = true;
          _loadMoreError = null;
        } else {
          _isLoading = true;
          _isRefreshing = _notifications.isNotEmpty;
          _isLoadingMore = false;
          _errorMessage = null;
          _loadMoreError = null;
        }
      });
    }

    try {
      final response = await auth.dio.get(
        '/notifications',
        queryParameters: {
          'limit': 30,
          if (loadMore && _nextCursor != null) 'cursor': _nextCursor,
        },
      );
      if (!mounted ||
          requestGeneration != _requestGeneration ||
          !_isCurrentSession(auth, accountId, sessionGeneration)) {
        return;
      }

      final data = response.data;
      final rawItems = data is List
          ? data
          : data is Map
              ? data['items']
              : null;
      if (rawItems is! List) {
        throw const FormatException('通知接口返回格式错误');
      }
      final items = rawItems
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
      final next = data is Map ? data['next_cursor']?.toString() : null;
      final hasMore = data is Map
          ? data['has_more'] == true || (next != null && next.isNotEmpty)
          : false;

      setState(() {
        if (loadMore) {
          final knownIds =
              _notifications.map(_notificationId).whereType<int>().toSet();
          _notifications = [
            ..._notifications,
            ...items.where((item) {
              final id = _notificationId(item);
              return id == null || knownIds.add(id);
            }),
          ];
        } else {
          _notifications = items;
        }
        _nextCursor = next == null || next.isEmpty ? null : next;
        _hasMore = hasMore && _nextCursor != null;
        _isLoading = false;
        _isRefreshing = false;
        _isLoadingMore = false;
        _loadMoreError = null;
        _errorMessage = null;
      });
    } on DioException catch (e) {
      _handleLoadError(
        auth,
        accountId,
        sessionGeneration,
        requestGeneration,
        loadMore,
        AppFeedback.dioErrorMessage(e, fallback: '通知加载失败'),
      );
    } catch (e) {
      _handleLoadError(
        auth,
        accountId,
        sessionGeneration,
        requestGeneration,
        loadMore,
        '通知加载失败，请稍后重试',
      );
    }
  }

  void _handleLoadError(
    AuthProvider auth,
    int accountId,
    int sessionGeneration,
    int requestGeneration,
    bool loadMore,
    String message,
  ) {
    if (!mounted ||
        requestGeneration != _requestGeneration ||
        !_isCurrentSession(auth, accountId, sessionGeneration)) {
      return;
    }
    setState(() {
      if (loadMore) {
        _isLoadingMore = false;
        _loadMoreError = message;
      } else {
        _isLoading = false;
        _isRefreshing = false;
        if (_notifications.isEmpty) {
          _errorMessage = message;
        }
      }
    });
    if (_notifications.isNotEmpty) {
      AppFeedback.showSnackBar(context, message, isError: true);
    }
  }

  String _formatTime(DateTime dateTime) {
    final now = DateTime.now();
    final diff = now.difference(dateTime);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes}分钟前';
    if (diff.inHours < 24) return '${diff.inHours}小时前';
    if (diff.inDays < 7) return '${diff.inDays}天前';
    return '${dateTime.year}-${dateTime.month.toString().padLeft(2, '0')}-${dateTime.day.toString().padLeft(2, '0')}';
  }

  Future<void> _markAllRead() async {
    final auth = context.read<AuthProvider>();
    final accountId = auth.user?.id;
    final sessionGeneration = auth.sessionGeneration;
    if (accountId == null) return;
    try {
      await ReplyNotificationService(auth.dio).markAllRead();
      if (!mounted || !_isCurrentSession(auth, accountId, sessionGeneration)) {
        return;
      }
      setState(() {
        for (var item in _notifications) {
          item['is_read'] = true;
        }
      });
      ReplyNotificationState.instance.notifyAllRead(
        accountId: accountId,
        sessionGeneration: sessionGeneration,
      );
      AppFeedback.showSnackBar(context, '已全部标记为已读');
    } catch (e) {
      if (mounted) {
        AppFeedback.showSnackBar(context, '操作失败', isError: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final auth = context.watch<AuthProvider>();

    if (!auth.isLoggedIn) {
      return Scaffold(
        appBar: AppBar(title: const Text('通知'), elevation: 0),
        body: _buildLoginRequiredView(isDark),
      );
    }

    final notificationBody = _isLoading && _notifications.isEmpty
        ? const Center(child: CircularProgressIndicator())
        : _errorMessage != null && _notifications.isEmpty
            ? _buildErrorView(isDark)
            : _notifications.isEmpty
                ? _buildEmptyView(isDark)
                : RefreshIndicator(
                    onRefresh: () => _loadReplies(),
                    child: ListView.separated(
                      controller: _scrollController,
                      physics: const AlwaysScrollableScrollPhysics(
                        parent: BouncingScrollPhysics(),
                      ),
                      padding: const EdgeInsets.all(16),
                      itemCount: _notifications.length +
                          (_hasMore || _isLoadingMore || _loadMoreError != null
                              ? 1
                              : 0),
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        if (index >= _notifications.length) {
                          return _buildLoadMoreFooter(isDark);
                        }
                        final notification = _notifications[index];
                        return _buildNotificationCard(notification, isDark);
                      },
                    ),
                  );

    return Scaffold(
      appBar: AppBar(
        title: const Text('通知'),
        elevation: 0,
        actions: [
          if (_notifications.any((n) => n['is_read'] != true))
            TextButton(
              onPressed: _markAllRead,
              child: const Text('全部已读'),
            ),
        ],
      ),
      body: Column(
        children: [
          if (_isRefreshing) const LinearProgressIndicator(minHeight: 2),
          Expanded(child: notificationBody),
        ],
      ),
    );
  }

  Widget _buildLoadMoreFooter(bool isDark) {
    if (_isLoadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Center(
        child: TextButton.icon(
          onPressed: () => _loadReplies(loadMore: true),
          icon: Icon(
            _loadMoreError == null ? Icons.expand_more : Icons.refresh,
            size: 18,
          ),
          label: Text(_loadMoreError ?? '加载更多通知'),
          style: TextButton.styleFrom(
            foregroundColor: isDark ? Colors.white70 : Colors.black54,
          ),
        ),
      ),
    );
  }

  Widget _buildNotificationCard(
      Map<String, dynamic> notification, bool isDark) {
    final id = _notificationId(notification);
    final type = notification['type'] as String?;
    final postId = notification['post_id'] as int?;
    final relatedId = notification['related_id'] as int?;
    final content = notification['content']?.toString() ?? '';
    final createdAt =
        DateTime.tryParse(notification['created_at'] ?? '') ?? DateTime.now();
    final fromUser = notification['from_user'] as Map<String, dynamic>?;
    final isRead = notification['is_read'] == true;

    String actionText = '';
    String titleText = '系统通知';
    if (type == 'reply') {
      actionText = '回复了您的帖子';
      titleText = fromUser?['nickname'] ?? '匿名用户';
    } else if (type == 'featured_application') {
      actionText = '精华申请通知';
    } else if (type == 'market_post') {
      actionText = '集市上新';
    } else if (type == 'water_moderation') {
      actionText = '水帖管理通知';
    } else if (type == 'team_application') {
      actionText = '有人申请加入你的组队';
    } else if (type == 'team_application_result') {
      actionText = '组队申请结果';
    } else if (type == 'team_deadline_soon') {
      actionText = '组队即将截止';
    } else if (type == 'team_member_left') {
      actionText = '有成员退出了你的组队';
    } else if (type == 'team_member_removed') {
      actionText = '你已被移出组队';
    }

    return InkWell(
      onTap: () async {
        final auth = context.read<AuthProvider>();
        if (id != null && !_openingNotificationIds.add(id)) return;
        try {
          if (!isRead && id != null) {
            final accountId = auth.user?.id;
            final sessionGeneration = auth.sessionGeneration;
            if (accountId == null) return;
            try {
              await ReplyNotificationService(auth.dio).markRead(id);
              if (!_isCurrentSession(auth, accountId, sessionGeneration)) {
                return;
              }
              setState(() {
                notification['is_read'] = true;
              });
              if (type == 'reply') {
                ReplyNotificationState.instance.markRead(
                  accountId: accountId,
                  sessionGeneration: sessionGeneration,
                  notificationId: id,
                );
              }
            } catch (error) {
              if (!mounted) return;
              AppFeedback.showSnackBar(
                context,
                '标记已读失败，请重试',
                isError: true,
              );
            }
          }

          if (postId != null) {
            try {
              final response = await auth.dio.get('/posts/$postId');
              if (!mounted) return;
              final post = Post.fromJson(
                  Map<String, dynamic>.from(response.data as Map));
              await Navigator.push(
                  context,
                  buildPostDetailRoute(post,
                      targetReplyId: type == 'reply' ? relatedId : null));
            } on DioException catch (error) {
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text(
                      AppFeedback.dioErrorMessage(error, fallback: '打开帖子失败'))));
            }
          }
        } finally {
          if (id != null) _openingNotificationIds.remove(id);
        }
      },
      borderRadius: BorderRadius.circular(12),
      child: GlassContainer(
        padding: const EdgeInsets.all(12),
        borderRadius: 12,
        blur: 0,
        showHighlight: false,
        backgroundColor: isDark
            ? const Color(0xFF1E2226).withValues(alpha: 0.96)
            : Colors.white.withValues(alpha: 0.94),
        borderColor: isDark
            ? Colors.white.withValues(alpha: 0.08)
            : const Color(0xFFECEEF1),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (fromUser != null)
              CachedAvatar(
                radius: 20,
                imageUrl: fromUser['avatar']?.toString().isNotEmpty == true
                    ? ApiConstants.fullUrl(fromUser['avatar'].toString())
                    : null,
                fallbackText: fromUser['nickname']?.toString(),
              )
            else
              CircleAvatar(
                radius: 20,
                backgroundColor:
                    Theme.of(context).primaryColor.withValues(alpha: 0.1),
                child: Icon(
                  type == 'water_moderation'
                      ? Icons.admin_panel_settings_outlined
                      : Icons.notifications,
                  color: Theme.of(context).primaryColor,
                  size: 20,
                ),
              ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        titleText,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: isDark ? Colors.white : Colors.black87,
                        ),
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (!isRead)
                            Container(
                              margin: const EdgeInsets.only(right: 6),
                              width: 8,
                              height: 8,
                              decoration: const BoxDecoration(
                                color: Colors.redAccent,
                                shape: BoxShape.circle,
                              ),
                            ),
                          Text(
                            _formatTime(createdAt),
                            style: TextStyle(
                              fontSize: 12,
                              color: isDark ? Colors.white30 : Colors.black54,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    actionText,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).primaryColor,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    content,
                    style: TextStyle(
                      fontSize: 14,
                      color: isDark ? Colors.white70 : Colors.black87,
                      height: 1.4,
                    ),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  bool _isCurrentSession(
    AuthProvider auth,
    int accountId,
    int sessionGeneration,
  ) {
    return mounted &&
        auth.isLoggedIn &&
        auth.user?.id == accountId &&
        auth.sessionGeneration == sessionGeneration;
  }

  Widget _buildEmptyView(bool isDark) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.forum_outlined,
            size: 64,
            color: isDark ? Colors.white30 : Colors.grey[400],
          ),
          const SizedBox(height: 16),
          Text(
            '暂无通知',
            style: TextStyle(
              color: isDark ? Colors.white60 : Colors.grey[600],
              fontSize: 16,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorView(bool isDark) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline,
              size: 64,
              color: isDark ? Colors.white30 : Colors.grey[400],
            ),
            const SizedBox(height: 16),
            Text(
              _errorMessage ?? '加载失败',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: isDark ? Colors.white60 : Colors.grey[600],
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _loadReplies,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLoginRequiredView(bool isDark) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.lock_outline,
              size: 64,
              color: isDark ? Colors.white30 : Colors.grey[400],
            ),
            const SizedBox(height: 16),
            Text(
              '登录后查看通知\n评论回复、系统提醒、管理通知会显示在这里',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: isDark ? Colors.white60 : Colors.grey[600],
                fontSize: 16,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () async {
                await Navigator.pushNamed(context, '/login');
                if (mounted && context.read<AuthProvider>().isLoggedIn) {
                  _loadReplies();
                }
              },
              icon: const Icon(Icons.login),
              label: const Text('去登录'),
            ),
          ],
        ),
      ),
    );
  }
}
