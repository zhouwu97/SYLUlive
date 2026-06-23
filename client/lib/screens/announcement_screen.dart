import 'dart:io' show File;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/api_constants.dart';
import '../models/announcement.dart' as model;
import '../providers/auth_provider.dart';
import '../providers/theme_provider.dart';
import '../widgets/glass_container.dart';

class AnnouncementScreen extends StatefulWidget {
  const AnnouncementScreen({super.key});

  @override
  State<AnnouncementScreen> createState() => _AnnouncementScreenState();
}

class _AnnouncementScreenState extends State<AnnouncementScreen>
    with SingleTickerProviderStateMixin {
  List<model.Announcement> _announcements = [];
  bool _isLoading = true;
  late AnimationController _animationController;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _loadAnnouncements();
    _animationController.forward();
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  Future<void> _loadAnnouncements() async {
    final authProvider = context.read<AuthProvider>();
    try {
      var response;
      try {
        response = await authProvider.dio.get(ApiConstants.noticesPath);
      } on DioException catch (e) {
        if (e.response?.statusCode == 404) {
          response = await authProvider.dio.get('/announcements');
        } else {
          rethrow;
        }
      }

      if (response.statusCode == 200) {
        final list = (response.data as List)
            .map((e) => model.Announcement.fromJson(e))
            .toList()
          ..sort((a, b) {
            if (a.isPinned != b.isPinned) {
              return a.isPinned ? -1 : 1;
            }
            return b.createdAt.compareTo(a.createdAt);
          });
        if (mounted)
          setState(() {
            _announcements = list;
            _isLoading = false;
          });
      }
    } catch (e) {
      debugPrint('加载公告失败: $e');
      if (mounted)
        setState(() {
          _isLoading = false;
        });
    }
  }

  Widget _buildDefaultBg(bool isDark) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Image.asset(
          'assets/images/morenbeijing.jpeg',
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => Container(
            color: isDark ? const Color(0xFF131720) : const Color(0xFFF4F6FB),
          ),
        ),
        Container(
          color: isDark
              ? Colors.black.withValues(alpha: 0.34)
              : Colors.white.withValues(alpha: 0.20),
        ),
      ],
    );
  }

  Widget _buildBackground(ThemeProvider themeProvider, bool isDark) {
    final path = themeProvider.getBackgroundImageFor(context);
    if (themeProvider.isBackgroundVisible && path != null && path.isNotEmpty) {
      final isAsset = !path.startsWith('http') && !path.startsWith('/');
      return Stack(
        fit: StackFit.expand,
        children: [
          isAsset
              ? Image.asset(
                  'assets/images/$path',
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => _buildDefaultBg(isDark),
                )
              : path.startsWith('/')
                  ? Image.file(
                      File(path),
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => _buildDefaultBg(isDark),
                    )
                  : Image.network(
                      path,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => _buildDefaultBg(isDark),
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
    final pinned = _announcements.where((a) => a.isPinned).toList();
    final regular = _announcements.where((a) => !a.isPinned).toList();

    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text(
          '公告',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        leading: const BackButton(),
      ),
      body: Stack(
        children: [
          Positioned.fill(child: _buildBackground(themeProvider, isDark)),
          FadeTransition(
            opacity: CurvedAnimation(
              parent: _animationController,
              curve: Curves.easeOut,
            ),
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _announcements.isEmpty
                    ? _buildEmptyState(isDark)
                    : RefreshIndicator(
                        onRefresh: _loadAnnouncements,
                        child: ListView(
                          physics: const BouncingScrollPhysics(),
                          padding: EdgeInsets.fromLTRB(12, topInset, 12, 100),
                          children: [
                            if (pinned.isNotEmpty) ...[
                              _buildSectionHeader(
                                isDark,
                                icon: Icons.push_pin_rounded,
                                title: '置顶公告',
                                subtitle: '${pinned.length} 条需要优先查看',
                                accent: Colors.red,
                              ),
                              const SizedBox(height: 10),
                              ...List.generate(
                                pinned.length,
                                (index) => _AnnouncementCard(
                                  announcement: pinned[index],
                                  isDark: isDark,
                                  index: index,
                                  emphasized: true,
                                  timeText:
                                      _formatTime(pinned[index].createdAt),
                                ),
                              ),
                              const SizedBox(height: 6),
                            ],
                            _buildSectionHeader(
                              isDark,
                              icon: Icons.history_rounded,
                              title: pinned.isEmpty ? '全部公告' : '最新公告',
                              subtitle: '${regular.length} 条按时间排序',
                              accent: Theme.of(context).primaryColor,
                            ),
                            const SizedBox(height: 10),
                            ...List.generate(
                              regular.length,
                              (index) => _AnnouncementCard(
                                announcement: regular[index],
                                isDark: isDark,
                                index: index + pinned.length,
                                timeText: _formatTime(regular[index].createdAt),
                              ),
                            ),
                          ],
                        ),
                      ),
          ),
        ],
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

  const _AnnouncementCard({
    required this.announcement,
    required this.isDark,
    required this.index,
    this.emphasized = false,
    required this.timeText,
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
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: Duration(milliseconds: 300 + (widget.index * 50).clamp(0, 300)),
      curve: Curves.easeOutCubic,
      builder: (context, value, child) {
        return Transform.translate(
          offset: Offset(0, 20 * (1 - value)),
          child: Opacity(
            opacity: value,
            child: child,
          ),
        );
      },
      child: GlassContainer(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        borderRadius: 16,
        blur: 10,
        opacity: widget.isDark ? 0.15 : 0.3,
        backgroundColor: widget.emphasized
            ? (widget.isDark
                ? const Color(0x99A32020)
                : const Color(0xFFFDF0F0))
            : null,
        borderColor: widget.emphasized
            ? Colors.red.withValues(alpha: widget.isDark ? 0.35 : 0.22)
            : null,
        onTap: widget.emphasized
            ? () {
                if (mounted)
                  setState(() {
                    _expanded = !_expanded;
                  });
              }
            : null,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (widget.announcement.isPinned) ...[
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
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
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Text(
                    widget.announcement.title,
                    maxLines: _expanded ? null : 1,
                    overflow: _expanded ? null : TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
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
                    color: widget.isDark ? Colors.white30 : Colors.grey[500],
                  ),
                  const SizedBox(width: 4),
                  Text(
                    widget.timeText,
                    style: TextStyle(
                      fontSize: 12,
                      color: widget.isDark ? Colors.white30 : Colors.grey[500],
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 将文字中的 URL 渲染为可点击链接
  Widget _buildRichContent(String text, bool isDark) {
    final urlRegex = RegExp(r'(https?://[^\s]+)');
    final matches = urlRegex.allMatches(text);
    if (matches.isEmpty) {
      return Text(text,
          style: TextStyle(
              fontSize: 14,
              color: isDark ? Colors.white70 : Colors.black87,
              height: 1.5));
    }

    final spans = <TextSpan>[];
    var lastEnd = 0;
    for (final match in matches) {
      if (match.start > lastEnd) {
        spans.add(TextSpan(text: text.substring(lastEnd, match.start)));
      }
      final url = match.group(1)!;
      spans.add(TextSpan(
        text: url,
        style: TextStyle(
            color: Colors.blue[400], decoration: TextDecoration.underline),
        recognizer: TapGestureRecognizer()..onTap = () => _openUrl(url),
      ));
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
            height: 1.5),
        children: spans,
      ),
    );
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri != null && await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }
}
