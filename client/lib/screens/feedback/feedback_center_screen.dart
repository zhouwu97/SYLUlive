import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/feedback_ticket.dart';
import '../../providers/auth_provider.dart';
import '../../providers/theme_provider.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_radius.dart';
import 'feedback_create_screen.dart';
import 'feedback_detail_screen.dart';

class FeedbackCenterScreen extends StatefulWidget {
  const FeedbackCenterScreen({super.key});

  @override
  State<FeedbackCenterScreen> createState() => _FeedbackCenterScreenState();
}

class _FeedbackCenterScreenState extends State<FeedbackCenterScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final List<String> _tabs = ['全部', '处理中', '待我补充', '已解决'];

  final Map<int, List<FeedbackTicket>> _tabTickets = {};
  final Map<int, bool> _tabLoading = {};
  final Map<int, String?> _tabErrors = {};
  final Map<int, int> _tabPages = {};
  final Map<int, bool> _tabHasMore = {};

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _tabs.length, vsync: this);
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging) {
        _loadTicketsForTab(_tabController.index);
      }
    });
    _loadTicketsForTab(0);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  String _statusGroupForIndex(int index) {
    switch (index) {
      case 1:
        return 'processing';
      case 2:
        return 'waiting_user';
      case 3:
        return 'resolved';
      default:
        return 'all';
    }
  }

  Future<void> _loadTicketsForTab(int tabIndex, {bool loadMore = false}) async {
    if ((_tabLoading[tabIndex] ?? false) ||
        (loadMore && !(_tabHasMore[tabIndex] ?? true))) {
      return;
    }
    final page = loadMore ? ((_tabPages[tabIndex] ?? 0) + 1) : 1;
    setState(() {
      _tabLoading[tabIndex] = true;
      if (!loadMore) {
        _tabErrors[tabIndex] = null;
        _tabPages[tabIndex] = 0;
        _tabHasMore[tabIndex] = true;
      }
    });

    try {
      final auth = context.read<AuthProvider>();
      final statusGroup = _statusGroupForIndex(tabIndex);
      final response = await auth.dio.get(
        '/feedback/tickets',
        queryParameters: {
          'status_group': statusGroup,
          'page': page,
          'limit': 50,
        },
      );

      if (response.statusCode == 200 && response.data != null) {
        final list = (response.data['tickets'] as List<dynamic>?) ?? [];
        final tickets = list
            .map((e) => FeedbackTicket.fromJson(e as Map<String, dynamic>))
            .toList();
        final total = (response.data['total'] as num?)?.toInt();

        if (mounted) {
          setState(() {
            final existing = loadMore
                ? List<FeedbackTicket>.from(_tabTickets[tabIndex] ?? const [])
                : <FeedbackTicket>[];
            final existingIds = existing.map((ticket) => ticket.id).toSet();
            existing.addAll(
              tickets.where((ticket) => existingIds.add(ticket.id)),
            );
            _tabTickets[tabIndex] = existing;
            _tabPages[tabIndex] = page;
            _tabHasMore[tabIndex] = total == null
                ? tickets.length >= 50
                : existing.length < total;
            _tabLoading[tabIndex] = false;
          });
        }
      } else {
        if (mounted) {
          setState(() {
            _tabLoading[tabIndex] = false;
            _tabErrors[tabIndex] = '加载失败，请下拉重试';
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _tabLoading[tabIndex] = false;
          _tabErrors[tabIndex] = '网络连接异常，请下拉重试';
        });
      }
    }
  }

  String _formatTimeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return '刚刚更新';
    if (diff.inMinutes < 60) return '${diff.inMinutes}分钟前更新';
    if (diff.inHours < 24) return '${diff.inHours}小时前更新';
    if (diff.inDays == 1) return '昨天更新';
    if (diff.inDays < 7) return '${diff.inDays}天前更新';
    return '${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}更新';
  }

  Color _getStatusColor(String status, bool isDark) {
    switch (status) {
      case 'pending':
        return Colors.orange;
      case 'accepted':
        return AppColors.brandPrimary;
      case 'waiting_user':
        return const Color(0xFFE65100);
      case 'investigating':
      case 'fixing':
        return Colors.blue;
      case 'testing':
        return Colors.teal;
      case 'resolved':
      case 'closed':
        return Colors.green;
      default:
        return isDark ? Colors.white70 : Colors.grey;
    }
  }

  Widget _buildStatusBadge(FeedbackTicket ticket, bool isDark) {
    final statusColor = _getStatusColor(ticket.status, isDark);
    final text = ticket.statusDisplayName;

    final isWaitingUser = ticket.status == 'waiting_user';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: isWaitingUser
            ? const Color(0xFFFFECE0)
            : statusColor.withValues(alpha: isDark ? 0.2 : 0.1),
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: isWaitingUser
            ? Border.all(color: const Color(0xFFFF7A45), width: 0.8)
            : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isWaitingUser) ...[
            const Icon(Icons.warning_amber_rounded,
                size: 13, color: Color(0xFFD4380D)),
            const SizedBox(width: 3),
          ],
          Text(
            text,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: isWaitingUser ? const Color(0xFFD4380D) : statusColor,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTypeTag(String type, bool isDark) {
    Color bg;
    Color fg;
    String label;
    switch (type) {
      case 'bug':
        bg = isDark ? Colors.red.withValues(alpha: 0.2) : const Color(0xFFFFEEEE);
        fg = const Color(0xFFE53E3E);
        label = '问题反馈';
        break;
      case 'suggestion':
        bg = isDark ? Colors.blue.withValues(alpha: 0.2) : const Color(0xFFEFF6FF);
        fg = const Color(0xFF2563EB);
        label = '功能建议';
        break;
      default:
        bg = isDark ? Colors.grey.withValues(alpha: 0.2) : const Color(0xFFF3F4F6);
        fg = const Color(0xFF6B7280);
        label = '其他';
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: fg),
      ),
    );
  }

  Widget _buildTicketCard(FeedbackTicket ticket, bool isDark) {
    final cardBg = isDark ? const Color(0xFF1E2226) : Colors.white;
    final borderColor = isDark ? Colors.white12 : const Color(0xFFE8EEE9);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: borderColor, width: 0.8),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          onTap: () async {
            await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => FeedbackDetailScreen(
                  ticketId: ticket.id,
                  isAdmin: false,
                ),
              ),
            );
            // 从详情页返回后刷新当前 Tab
            _loadTicketsForTab(_tabController.index);
          },
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 顶部：类型标签 + 状态 Badge + 未读红点
                Row(
                  children: [
                    _buildTypeTag(ticket.type, isDark),
                    const Spacer(),
                    if (ticket.userUnreadCount > 0)
                      Container(
                        margin: const EdgeInsets.only(right: 6),
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(
                          color: Colors.red,
                          shape: BoxShape.circle,
                        ),
                      ),
                    _buildStatusBadge(ticket, isDark),
                  ],
                ),
                const SizedBox(height: 10),

                // 标题
                Text(
                  ticket.title,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: isDark ? Colors.white : const Color(0xFF1F2328),
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),

                // 最新回复/状态说明
                if (ticket.latestReplySnippet != null &&
                    ticket.latestReplySnippet!.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: isDark
                          ? Colors.white.withValues(alpha: 0.04)
                          : const Color(0xFFF8FAF9),
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                    ),
                    child: Text(
                      ticket.latestReplySnippet!,
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark ? Colors.white70 : const Color(0xFF4A5568),
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],

                const SizedBox(height: 10),

                // 单号与更新时间
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '#${ticket.ticketNo}',
                      style: TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        color: isDark ? Colors.white38 : Colors.grey[500],
                      ),
                    ),
                    Text(
                      _formatTimeAgo(ticket.updatedAt),
                      style: TextStyle(
                        fontSize: 11,
                        color: isDark ? Colors.white38 : Colors.grey[500],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTopBanner(bool isDark) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      decoration: BoxDecoration(
        color: isDark
            ? const Color(0xFF1B2A27)
            : const Color(0xFFF0FDF8), // 清淡青绿底
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(
          color: isDark ? Colors.teal.shade900 : const Color(0xFFD1FAE5),
          width: 0.8,
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '遇到问题或有新的想法？',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: isDark ? Colors.white : const Color(0xFF065F46),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '我们会持续跟进你的反馈',
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark ? Colors.white70 : const Color(0xFF047857),
                  ),
                ),
              ],
            ),
          ),
          ElevatedButton.icon(
            onPressed: () async {
              final result = await Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const FeedbackCreateScreen()),
              );
              if (result == true) {
                _loadTicketsForTab(_tabController.index);
              }
            },
            icon: const Icon(Icons.add, size: 16),
            label: const Text('新建反馈'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.brandPrimary,
              foregroundColor: Colors.white,
              elevation: 0,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(999),
              ),
              textStyle: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabContent(int tabIndex, bool isDark) {
    final loading = _tabLoading[tabIndex] ?? false;
    final error = _tabErrors[tabIndex];
    final tickets = _tabTickets[tabIndex] ?? [];

    if (loading && tickets.isEmpty) {
      return const Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(strokeWidth: 2.5),
        ),
      );
    }

    if (error != null && tickets.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.wifi_off_rounded,
                size: 44, color: isDark ? Colors.white38 : Colors.grey[400]),
            const SizedBox(height: 12),
            Text(
              error,
              style: TextStyle(
                fontSize: 13,
                color: isDark ? Colors.white54 : Colors.grey[600],
              ),
            ),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: () => _loadTicketsForTab(tabIndex),
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }

    if (tickets.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.assignment_turned_in_outlined,
              size: 48,
              color: isDark ? Colors.white24 : Colors.grey[300],
            ),
            const SizedBox(height: 12),
            Text(
              tabIndex == 0 ? '暂无反馈记录' : '当前分类下没有工单',
              style: TextStyle(
                fontSize: 14,
                color: isDark ? Colors.white38 : Colors.grey[500],
              ),
            ),
          ],
        ),
      );
    }

    final hasMore = _tabHasMore[tabIndex] ?? false;
    return RefreshIndicator(
      onRefresh: () => _loadTicketsForTab(tabIndex),
      color: AppColors.brandPrimary,
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (notification.metrics.extentAfter < 300 &&
              notification is ScrollUpdateNotification) {
            _loadTicketsForTab(tabIndex, loadMore: true);
          }
          return false;
        },
        child: ListView.builder(
          physics: const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics(),
          ),
          padding: const EdgeInsets.only(top: 4, bottom: 24),
          itemCount: tickets.length + (hasMore ? 1 : 0),
          itemBuilder: (_, index) {
            if (index >= tickets.length) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              );
            }
            return _buildTicketCard(tickets[index], isDark);
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = context.watch<ThemeProvider>();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final pageBg = themeProvider.isCleanBackgroundMode && !isDark
        ? const Color(0xFFFFFAF4)
        : Theme.of(context).colorScheme.surface;

    return Scaffold(
      backgroundColor: pageBg,
      appBar: AppBar(
        title: const Text(
          '帮助与反馈',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
        ),
        centerTitle: true,
        elevation: 0,
        backgroundColor: pageBg,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Column(
        children: [
          _buildTopBanner(isDark),
          Container(
            height: 42,
            margin: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: isDark ? Colors.white.withValues(alpha: 0.05) : const Color(0xFFF1F5F3),
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            child: TabBar(
              controller: _tabController,
              indicator: BoxDecoration(
                color: isDark ? const Color(0xFF262C33) : Colors.white,
                borderRadius: BorderRadius.circular(AppRadius.md - 2),
                boxShadow: isDark
                    ? null
                    : [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.04),
                          blurRadius: 4,
                          offset: const Offset(0, 1),
                        ),
                      ],
              ),
              indicatorSize: TabBarIndicatorSize.tab,
              dividerColor: Colors.transparent,
              labelColor: isDark ? Colors.white : AppColors.brandPrimary,
              unselectedLabelColor: isDark ? Colors.white54 : const Color(0xFF718096),
              labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
              unselectedLabelStyle: const TextStyle(fontSize: 13),
              tabs: _tabs.map((tab) => Tab(text: tab)).toList(),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: List.generate(
                _tabs.length,
                (index) => _buildTabContent(index, isDark),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
