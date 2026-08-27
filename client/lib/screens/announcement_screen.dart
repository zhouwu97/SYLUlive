import 'dart:io' show File;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:dio/dio.dart';
import '../platform/contracts/external_navigator.dart';

import '../config/api_constants.dart';
import '../models/announcement.dart' as model;
import '../providers/auth_provider.dart';
import '../providers/theme_provider.dart';
import '../theme/app_colors.dart';
import '../theme/app_motion.dart';
import '../widgets/glass_container.dart';
import '../widgets/app_cached_image.dart';

class AnnouncementScreen extends StatefulWidget {
  const AnnouncementScreen({super.key, this.onAnnouncementRead});

  final ValueChanged<int>? onAnnouncementRead;

  @override
  State<AnnouncementScreen> createState() => _AnnouncementScreenState();
}

class _AnnouncementScreenState extends State<AnnouncementScreen> {
  List<model.Announcement> _announcements = [];
  Set<int> _unreadAnnouncementIds = {};
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadAnnouncements();
  }

  @override
  void dispose() {
    super.dispose();
  }

  Future<void> _loadAnnouncements() async {
    final authProvider = context.read<AuthProvider>();
    final sessionGeneration = authProvider.sessionGeneration;
    final unreadFuture = _loadUnreadAnnouncements(authProvider);
    try {
      final response = await _getAnnouncements(
        authProvider,
        unreadOnly: false,
      );
      final all = _parseAnnouncements(response);
      final loadedUnread = await unreadFuture;
      final unread = authProvider.isLoggedIn &&
              authProvider.sessionGeneration == sessionGeneration
          ? loadedUnread
          : <model.Announcement>[];
      if (!mounted) return;
      setState(() {
        _announcements = all;
        _unreadAnnouncementIds = unread.map((item) => item.id).toSet();
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('加载公告失败: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<List<model.Announcement>> _loadUnreadAnnouncements(
    AuthProvider authProvider,
  ) async {
    if (!authProvider.isLoggedIn) return [];
    try {
      final response = await _getAnnouncements(
        authProvider,
        unreadOnly: true,
      );
      return _parseAnnouncements(response);
    } catch (e) {
      debugPrint('加载未读公告失败: $e');
      return [];
    }
  }

  Future<Response<dynamic>> _getAnnouncements(
    AuthProvider authProvider, {
    required bool unreadOnly,
  }) async {
    final primaryPath = unreadOnly
        ? '${ApiConstants.noticesPath}/unread'
        : ApiConstants.noticesPath;
    final fallbackPath =
        unreadOnly ? '/announcements/unread' : '/announcements';
    try {
      return await authProvider.dio.get(primaryPath);
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        return authProvider.dio.get(fallbackPath);
      }
      rethrow;
    }
  }

  List<model.Announcement> _parseAnnouncements(Response<dynamic> response) {
    if (response.statusCode != 200 || response.data is! List) return [];
    return (response.data as List)
        .map((item) => model.Announcement.fromJson(item))
        .toList()
      ..sort(model.Announcement.compareForDisplay);
  }

  Future<void> _markAnnouncementRead(model.Announcement announcement) async {
    try {
      final dio = context.read<AuthProvider>().dio;
      try {
        await dio.post('${ApiConstants.noticesPath}/${announcement.id}/read');
      } on DioException catch (e) {
        if (e.response?.statusCode == 404) {
          await dio.post('/announcements/${announcement.id}/read');
        } else {
          rethrow;
        }
      }
      if (!mounted) return;
      setState(() {
        _unreadAnnouncementIds.remove(announcement.id);
      });
      widget.onAnnouncementRead?.call(announcement.id);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('标记公告已读失败，请稍后重试')),
      );
    }
  }

  Widget _buildDefaultBg(bool isDark) {
    return ColoredBox(
      color: isDark ? const Color(0xFF131720) : kCleanWarmBackgroundLight,
    );
  }

  Widget _buildBackground(ThemeProvider themeProvider, bool isDark) {
    final path = themeProvider.getCustomBackgroundImageFor(context);
    if (themeProvider.shouldShowCustomBackground &&
        path != null &&
        path.isNotEmpty) {
      return Stack(
        fit: StackFit.expand,
        children: [
          ThemeProvider.isBundledAssetBackground(path)
              ? Image.asset(
                  ThemeProvider.resolveBundledAssetPath(path),
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => _buildDefaultBg(isDark),
                )
              : ThemeProvider.isLocalFileBackground(path)
                  ? Image.file(
                      File(path),
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => _buildDefaultBg(isDark),
                    )
                  : AppCachedImage.public(
                      imageUrl: path,
                      fit: BoxFit.cover,
                      memCacheWidth: 2048,
                      memCacheHeight: 2048,
                      errorWidget: (_, __, ___) => _buildDefaultBg(isDark),
                    ),
          Container(
            color: isDark
                ? Colors.black.withValues(alpha: 0.34)
                : Colors.white.withValues(alpha: 0.20),
          ),
        ],
      );
    }
    return _buildDefaultBg(isDark);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final themeProvider = context.watch<ThemeProvider>();
    final topInset = MediaQuery.paddingOf(context).top + kToolbarHeight + 12;
    final unread = _announcements
        .where((item) => _unreadAnnouncementIds.contains(item.id))
        .toList()
      ..sort(model.Announcement.compareForDisplay);
    final history = _announcements
        .where((item) => !_unreadAnnouncementIds.contains(item.id))
        .toList()
      ..sort(model.Announcement.compareForDisplay);
    final useCustomBackground = themeProvider.shouldShowCustomBackground;
    final cleanLightMode = !useCustomBackground && !isDark;
    final foregroundColor =
        cleanLightMode ? const Color(0xFF1F2937) : Colors.white;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: (cleanLightMode
              ? SystemUiOverlayStyle.dark
              : SystemUiOverlayStyle.light)
          .copyWith(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
      ),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          foregroundColor: foregroundColor,
          backgroundColor: Colors.transparent,
          elevation: 0,
          title: Text(
            '公告中心',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: foregroundColor,
            ),
          ),
          leading: const BackButton(),
        ),
        body: Stack(
          children: [
            Positioned.fill(child: _buildBackground(themeProvider, isDark)),
            _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _announcements.isEmpty
                    ? _buildEmptyState(isDark)
                    : RefreshIndicator(
                        onRefresh: _loadAnnouncements,
                        child: ListView(
                          physics: const BouncingScrollPhysics(),
                          padding: EdgeInsets.fromLTRB(12, topInset, 12, 100),
                          children: [
                            if (unread.isNotEmpty) ...[
                              _buildSectionHeader(
                                isDark,
                                icon: Icons.mark_email_unread_outlined,
                                title: '未读公告',
                                subtitle: '${unread.length} 条等待查看',
                                accent: Colors.red,
                              ),
                              const SizedBox(height: 10),
                              ...List.generate(
                                unread.length,
                                (index) => _AnnouncementCard(
                                  key: ValueKey(unread[index].id),
                                  announcement: unread[index],
                                  isDark: isDark,
                                  index: index,
                                  emphasized: unread[index].isPinned,
                                  timeText:
                                      _formatTime(unread[index].createdAt),
                                  onMarkRead: () =>
                                      _markAnnouncementRead(unread[index]),
                                ),
                              ),
                              const SizedBox(height: 6),
                            ],
                            if (history.isNotEmpty) ...[
                              _buildSectionHeader(
                                isDark,
                                icon: Icons.history_rounded,
                                title: '历史公告',
                                subtitle: '${history.length} 条，可随时查看',
                                accent: Theme.of(context).primaryColor,
                              ),
                              const SizedBox(height: 10),
                              ...List.generate(
                                history.length,
                                (index) => _AnnouncementCard(
                                  key: ValueKey(history[index].id),
                                  announcement: history[index],
                                  isDark: isDark,
                                  index: index + unread.length,
                                  emphasized: history[index].isPinned,
                                  timeText:
                                      _formatTime(history[index].createdAt),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(
    bool isDark, {
    required IconData icon,
    required String title,
    required String subtitle,
    required Color accent,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: accent, size: 18),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: isDark ? Colors.white : Colors.black87,
                  ),
                ),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: isDark ? Colors.white54 : Colors.black54,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(bool isDark) {
    return Center(
      child: GlassContainer(
        padding: const EdgeInsets.all(32),
        borderRadius: 20,
        blur: 15,
        opacity: 0.1,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.campaign_outlined,
              size: 64,
              color: isDark ? Colors.white60 : Colors.grey[400],
            ),
            const SizedBox(height: 16),
            Text(
              '暂无公告',
              style: TextStyle(
                fontSize: 18,
                color: isDark ? Colors.white70 : Colors.grey[600],
              ),
            ),
          ],
        ),
      ),
    );
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
}

class _AnnouncementCard extends StatefulWidget {
  final model.Announcement announcement;
  final bool isDark;
  final int index;
  final bool emphasized;
  final String timeText;
  final VoidCallback? onMarkRead;

  const _AnnouncementCard({
    super.key,
    required this.announcement,
    required this.isDark,
    required this.index,
    this.emphasized = false,
    required this.timeText,
    this.onMarkRead,
  });

  @override
  State<_AnnouncementCard> createState() => _AnnouncementCardState();
}

class _AnnouncementCardState extends State<_AnnouncementCard> {
  late bool _expanded;

  @override
  void initState() {
    super.initState();
    _expanded = !widget.emphasized; // 置顶公告默认收起，普通公告展开
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final staggerMs = (widget.index * 25).clamp(0, 50);

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: reduceMotion
          ? Duration.zero
          : Duration(milliseconds: 160 + staggerMs),
      curve: AppMotion.incoming,
      builder: (context, value, child) {
        return Transform.translate(
          offset: Offset(0, 6 * (1 - value)),
          child: Opacity(opacity: value, child: child),
        );
      },
      child: GlassContainer(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        borderRadius: 16,
        blur: 10,
        opacity: widget.emphasized ? (widget.isDark ? 0.15 : 0.3) : 0.96,
        backgroundColor: widget.emphasized
            ? (widget.isDark
                ? const Color(0x99A32020)
                : const Color(0xFFFDF0F0))
            : (widget.isDark
                ? AppColors.surfaceSecondaryDark
                : AppColors.surfaceSecondaryLight),
        borderColor: widget.emphasized
            ? Colors.red.withValues(alpha: widget.isDark ? 0.35 : 0.22)
            : (widget.isDark
                ? AppColors.borderNormalDark
                : AppColors.borderNormalLight),
        onTap: widget.emphasized
            ? () {
                if (mounted) {
                  setState(() {
                    _expanded = !_expanded;
                  });
                }
              }
            : null,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                // Priority badge
                _buildPriorityBadge(),
                if (widget.announcement.isPinned) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.red.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.push_pin, color: Colors.red, size: 12),
                        SizedBox(width: 4),
                        Text(
                          '置顶',
                          style: TextStyle(color: Colors.red, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ],
                // Status indicators
                if (_isExpired()) ...[
                  const SizedBox(width: 6),
                  _buildStatusBadge('已过期', Colors.grey),
                ],
                if (_isScheduled()) ...[
                  const SizedBox(width: 6),
                  _buildStatusBadge('即将发布', Colors.blue),
                ],
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.announcement.title,
                    maxLines: _expanded ? null : 1,
                    overflow: _expanded ? null : TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: widget.isDark ? Colors.white : Colors.black87,
                    ),
                  ),
                ),
                if (widget.emphasized)
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    color: widget.isDark ? Colors.white54 : Colors.black54,
                  ),
              ],
            ),
            if (_expanded) ...[
              const SizedBox(height: 12),
              _buildRichContent(widget.announcement.content, widget.isDark),
              const SizedBox(height: 12),
              Row(
                children: [
                  Icon(
                    Icons.access_time,
                    size: 14,
                    color: widget.isDark ? Colors.white54 : Colors.grey[600],
                  ),
                  const SizedBox(width: 4),
                  Text(
                    widget.timeText,
                    style: TextStyle(
                      fontSize: 12,
                      color: widget.isDark ? Colors.white54 : Colors.grey[600],
                    ),
                  ),
                  if (widget.announcement.creator != null) ...[
                    const SizedBox(width: 12),
                    Icon(
                      Icons.person_outline,
                      size: 14,
                      color: widget.isDark ? Colors.white54 : Colors.grey[600],
                    ),
                    const SizedBox(width: 4),
                    Text(
                      widget.announcement.creator!['nickname']?.toString() ??
                          '',
                      style: TextStyle(
                        fontSize: 12,
                        color:
                            widget.isDark ? Colors.white54 : Colors.grey[600],
                      ),
                    ),
                  ],
                ],
              ),
              if (widget.onMarkRead != null) ...[
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: widget.onMarkRead,
                    icon: const Icon(Icons.done_rounded, size: 16),
                    label: const Text('标为已读'),
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  bool _isExpired() {
    final e = widget.announcement.expiresAt;
    return e != null && e.isBefore(DateTime.now());
  }

  bool _isScheduled() {
    final p = widget.announcement.publishAt;
    return p != null && p.isAfter(DateTime.now());
  }

  Widget _buildPriorityBadge() {
    final p = widget.announcement.priority;
    if (p == 'normal') return const SizedBox.shrink();
    final isUrgent = p == 'urgent';
    final color = isUrgent ? Colors.red : Colors.orange;
    final label = isUrgent ? '紧急' : '重要';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(isUrgent ? Icons.warning_rounded : Icons.info_rounded,
              color: color, size: 12),
          const SizedBox(width: 4),
          Text(label,
              style: TextStyle(
                  color: color, fontSize: 12, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  Widget _buildStatusBadge(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(label,
          style: TextStyle(
              color: color, fontSize: 12, fontWeight: FontWeight.w600)),
    );
  }

  /// 将文字中的 URL 渲染为可点击链接
  Widget _buildRichContent(String text, bool isDark) {
    final urlRegex = RegExp(r'(https?://[^\s]+)');
    final matches = urlRegex.allMatches(text);
    if (matches.isEmpty) {
      return Text(
        text,
        style: TextStyle(
          fontSize: 14,
          color: isDark ? Colors.white70 : Colors.black87,
          height: 1.5,
        ),
      );
    }

    final spans = <TextSpan>[];
    var lastEnd = 0;
    for (final match in matches) {
      if (match.start > lastEnd) {
        spans.add(TextSpan(text: text.substring(lastEnd, match.start)));
      }
      final url = match.group(1)!;
      spans.add(
        TextSpan(
          text: url,
          style: TextStyle(
            color: Colors.blue[400],
            decoration: TextDecoration.underline,
          ),
          recognizer: TapGestureRecognizer()..onTap = () => _openUrl(url),
        ),
      );
      lastEnd = match.end;
    }
    if (lastEnd < text.length) {
      spans.add(TextSpan(text: text.substring(lastEnd)));
    }

    return RichText(
      text: TextSpan(
        style: TextStyle(
          fontSize: 14,
          color: isDark ? Colors.white70 : Colors.black87,
          height: 1.5,
        ),
        children: spans,
      ),
    );
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri != null) {
      await ExternalNavigator.current().open(uri);
    }
  }
}
