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
  bool _isLoading = true;
  String? _errorMessage;

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
    _loadReplies();
  }

  Future<void> _loadReplies() async {
    final auth = context.read<AuthProvider>();
    if (!auth.isLoggedIn) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _notifications = [];
          _errorMessage = null;
        });
      }
      return;
    }

    if (mounted) {
      setState(() {
        _isLoading = true;
        _errorMessage = null;
      });
    }

    try {
      final auth = context.read<AuthProvider>();
      final response = await auth.dio.get('/notifications');
      if (response.statusCode == 200) {
        final list = List<Map<String, dynamic>>.from(response.data as List);
        if (mounted) {
          setState(() {
            _notifications = list;
            _isLoading = false;
          });
        }
      } else {
        if (mounted) {
          setState(() {
            _errorMessage = '获取失败: ${response.statusCode}';
            _isLoading = false;
          });
        }
      }
    } on DioException catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = AppFeedback.dioErrorMessage(e, fallback: '通知加载失败');
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = '暂无网络或后端接口未部署\n详细信息: $e';
          _isLoading = false;
        });
      }
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
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _errorMessage != null
              ? _buildErrorView(isDark)
              : _notifications.isEmpty
                  ? _buildEmptyView(isDark)
                  : RefreshIndicator(
                      onRefresh: _loadReplies,
                      child: ListView.separated(
                        physics: const AlwaysScrollableScrollPhysics(
                          parent: BouncingScrollPhysics(),
                        ),
                        padding: const EdgeInsets.all(16),
                        itemCount: _notifications.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final notification = _notifications[index];
                          return _buildNotificationCard(notification, isDark);
                        },
                      ),
                    ),
    );
  }

  Widget _buildNotificationCard(
      Map<String, dynamic> notification, bool isDark) {
    final id = notification['id'] as int?;
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
              final post = Post.fromJson(Map<String, dynamic>.from(response.data as Map));
              await Navigator.push(context, buildPostDetailRoute(post, targetReplyId: type == 'reply' ? relatedId : null));
            } on DioException catch (error) {
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(AppFeedback.dioErrorMessage(error, fallback: '打开帖子失败'))));
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
        blur: 8,
        opacity: isDark ? 0.15 : 0.3,
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
