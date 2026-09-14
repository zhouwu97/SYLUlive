import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/feedback_ticket.dart';
import '../../providers/auth_provider.dart';
import '../../providers/theme_provider.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_radius.dart';
import '../feedback/feedback_detail_screen.dart';

class AdminFeedbackScreen extends StatefulWidget {
  const AdminFeedbackScreen({super.key});

  @override
  State<AdminFeedbackScreen> createState() => _AdminFeedbackScreenState();
}

class _AdminFeedbackScreenState extends State<AdminFeedbackScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final List<String> _tabs = ['未查看', '待受理', '处理中', '待补充', '测试中', '已解决'];

  final TextEditingController _searchController = TextEditingController();
  bool _showSearch = false;

  List<FeedbackTicket> _tickets = [];
  bool _loading = true;
  String? _error;

  // 概览统计数据
  int _pendingCount = 0;
  int _waitingCount = 0;
  int _testingCount = 0;
  int _unviewedCount = 0;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _tabs.length, vsync: this);
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging) {
        _loadTickets();
      }
    });
    _loadStats();
    _loadTickets();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  String _filterForTabIndex(int index) {
    switch (index) {
      case 0:
        return 'unviewed';
      case 1:
        return 'pending';
      case 2:
        return 'processing';
      case 3:
        return 'waiting_user';
      case 4:
        return 'testing';
      case 5:
        return 'resolved';
      default:
        return 'all';
    }
  }

  Future<void> _loadStats() async {
    try {
      final auth = context.read<AuthProvider>();
      final res = await auth.dio.get('/admin/feedback/tickets/stats');
      if (res.statusCode == 200 && res.data != null) {
        if (mounted) {
          setState(() {
            _pendingCount = res.data['pending_count'] as int? ?? 0;
            _waitingCount = res.data['waiting_user_count'] as int? ?? 0;
            _testingCount = res.data['testing_count'] as int? ?? 0;
            _unviewedCount = res.data['unviewed_count'] as int? ?? 0;
          });
        }
      }
    } catch (_) {}
  }

  Future<void> _loadTickets() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final auth = context.read<AuthProvider>();
      final filter = _filterForTabIndex(_tabController.index);
      final search = _searchController.text.trim();

      final res = await auth.dio.get(
        '/admin/feedback/tickets',
        queryParameters: {
          'status_filter': filter,
          if (search.isNotEmpty) 'search': search,
          'page': 1,
          'limit': 50,
        },
      );

      if (res.statusCode == 200 && res.data != null) {
        final list = (res.data['tickets'] as List<dynamic>?) ?? [];
        final tickets = list
            .map((e) => FeedbackTicket.fromJson(e as Map<String, dynamic>))
            .toList();

        if (mounted) {
          setState(() {
            _tickets = tickets;
            _loading = false;
          });
        }
      } else {
        if (mounted) {
          setState(() {
            _loading = false;
            _error = '工单列表加载失败';
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '网络连接异常';
        });
      }
    }
  }

  String _formatTimeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes}分钟前';
    if (diff.inHours < 24) return '${diff.inHours}小时前';
    if (diff.inDays == 1) return '昨天';
    return '${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }

  Widget _buildStatsHeader(bool isDark) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 10),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E2226) : Colors.white,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(
          color: isDark ? Colors.white12 : const Color(0xFFE8EEE9),
          width: 0.8,
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _buildStatItem('待处理', '$_pendingCount', Colors.orange),
          _buildStatDivider(isDark),
          _buildStatItem('待补充', '$_waitingCount', const Color(0xFFEA580C)),
          _buildStatDivider(isDark),
          _buildStatItem('测试中', '$_testingCount', Colors.teal),
          _buildStatDivider(isDark),
          _buildStatItem('未查看', '$_unviewedCount', Colors.red),
        ],
      ),
    );
  }

  Widget _buildStatDivider(bool isDark) {
    return Container(
      width: 1,
      height: 24,
      color: isDark ? Colors.white12 : const Color(0xFFE2EFEA),
    );
  }

  Widget _buildStatItem(String label, String count, Color color) {
    return Column(
      children: [
        Text(
          count,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: const TextStyle(fontSize: 12, color: Colors.grey),
        ),
      ],
    );
  }

  Widget _buildAdminTicketCard(FeedbackTicket ticket, bool isDark) {
    final cardBg = isDark ? const Color(0xFF1E2226) : Colors.white;
    final borderColor = isDark ? Colors.white12 : const Color(0xFFE8EEE9);

    final isUnviewed = !ticket.adminViewed;
    final isWaiting = ticket.status == 'waiting_user';

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(
          color: isUnviewed
              ? Colors.red.withValues(alpha: 0.5)
              : borderColor,
          width: isUnviewed ? 1.2 : 0.8,
        ),
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
                  isAdmin: true,
                ),
              ),
            );
            _loadStats();
            _loadTickets();
          },
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 顶部状态提示行
                Row(
                  children: [
                    if (isUnviewed) ...[
                      Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(
                          color: Colors.red,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      const Text(
                        '未查看',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: Colors.red,
                        ),
                      ),
                    ] else if (isWaiting) ...[
                      const Icon(Icons.warning_amber_rounded,
                          size: 14, color: Color(0xFFEA580C)),
                      const SizedBox(width: 4),
                      const Text(
                        '待用户补充',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFFEA580C),
                        ),
                      ),
                    ] else ...[
                      Text(
                        ticket.statusDisplayName,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: AppColors.brandPrimary,
                        ),
                      ),
                    ],
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: ticket.priority == 'P0'
                            ? Colors.red.withValues(alpha: 0.15)
                            : (ticket.priority == 'P1'
                                ? Colors.orange.withValues(alpha: 0.15)
                                : Colors.grey.withValues(alpha: 0.15)),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        ticket.priority,
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: ticket.priority == 'P0'
                              ? Colors.red
                              : (ticket.priority == 'P1'
                                  ? Colors.orange
                                  : Colors.grey[700]),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),

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

                const SizedBox(height: 8),

                // 底部单号、类型、时间
                Row(
                  children: [
                    Text(
                      ticket.typeLabel,
                      style: TextStyle(
                        fontSize: 11,
                        color: isDark ? Colors.white54 : Colors.grey[600],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '#${ticket.ticketNo}',
                      style: const TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        color: Colors.grey,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      _formatTimeAgo(ticket.updatedAt),
                      style: const TextStyle(fontSize: 11, color: Colors.grey),
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
        title: _showSearch
            ? TextField(
                controller: _searchController,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: '搜索工单号或关键词……',
                  border: InputBorder.none,
                ),
                onSubmitted: (_) => _loadTickets(),
              )
            : const Text(
                '工单管理',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
              ),
        centerTitle: true,
        elevation: 0,
        backgroundColor: pageBg,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            icon: Icon(_showSearch ? Icons.close : Icons.search),
            onPressed: () {
              setState(() {
                if (_showSearch) {
                  _showSearch = false;
                  _searchController.clear();
                  _loadTickets();
                } else {
                  _showSearch = true;
                }
              });
            },
          ),
        ],
      ),
      body: Column(
        children: [
          _buildStatsHeader(isDark),
          Container(
            height: 40,
            margin: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.05)
                  : const Color(0xFFF1F5F3),
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            child: TabBar(
              controller: _tabController,
              isScrollable: true,
              tabAlignment: TabAlignment.start,
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
              unselectedLabelColor:
                  isDark ? Colors.white54 : const Color(0xFF718096),
              labelStyle:
                  const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
              tabs: _tabs.map((t) => Tab(text: t)).toList(),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _loading
                ? const Center(
                    child: SizedBox(
                      width: 28,
                      height: 28,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    ),
                  )
                : _error != null
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(_error!),
                            const SizedBox(height: 12),
                            OutlinedButton(
                              onPressed: _loadTickets,
                              child: const Text('重试'),
                            ),
                          ],
                        ),
                      )
                    : _tickets.isEmpty
                        ? const Center(
                            child: Text(
                              '暂无符合条件的工单',
                              style: TextStyle(color: Colors.grey),
                            ),
                          )
                        : RefreshIndicator(
                            onRefresh: () async {
                              await _loadStats();
                              await _loadTickets();
                            },
                            color: AppColors.brandPrimary,
                            child: ListView.builder(
                              physics: const AlwaysScrollableScrollPhysics(
                                parent: BouncingScrollPhysics(),
                              ),
                              padding: const EdgeInsets.only(bottom: 24),
                              itemCount: _tickets.length,
                              itemBuilder: (_, idx) =>
                                  _buildAdminTicketCard(_tickets[idx], isDark),
                            ),
                          ),
          ),
        ],
      ),
    );
  }
}
