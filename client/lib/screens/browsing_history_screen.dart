import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../models/browsing_history_item.dart';
import '../models/campus_article.dart';
import '../providers/auth_provider.dart';
import '../repositories/browsing_history_repository.dart';
import '../theme/app_theme_tokens.dart';
import 'campus_article_detail_screen.dart';
import 'post_detail_screen.dart';

/// 浏览记录页面（BrowsingHistoryScreen）
class BrowsingHistoryScreen extends StatefulWidget {
  const BrowsingHistoryScreen({super.key});

  @override
  State<BrowsingHistoryScreen> createState() => _BrowsingHistoryScreenState();
}

class _BrowsingHistoryScreenState extends State<BrowsingHistoryScreen>
    with SingleTickerProviderStateMixin {
  final BrowsingHistoryRepository _repository = BrowsingHistoryRepository();
  late TabController _tabController;

  bool _isLoading = true;
  List<BrowsingHistoryItem> _allItems = [];
  int _observedAccountEpoch = -1;
  int _historyLoadSerial = 0;

  final List<({String label, BrowsingHistoryType? type})> _tabs = [
    (label: '全部', type: null),
    (label: '校园资讯', type: BrowsingHistoryType.campusNews),
    (label: '帖子', type: BrowsingHistoryType.post),
  ];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _tabs.length, vsync: this);
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging) setState(() {});
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final auth = context.watch<AuthProvider>();
    if (_observedAccountEpoch == auth.accountSessionEpoch) return;
    _observedAccountEpoch = auth.accountSessionEpoch;
    _allItems = [];
    _isLoading = true;
    final serial = ++_historyLoadSerial;
    final userId = auth.user?.id.toString();
    final epoch = auth.accountSessionEpoch;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadHistory(userId: userId, expectedEpoch: epoch, serial: serial);
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadHistory({
    String? userId,
    int? expectedEpoch,
    int? serial,
  }) async {
    if (!mounted) return;
    final auth = context.read<AuthProvider>();
    final capturedUserId = userId ?? auth.user?.id.toString();
    final capturedEpoch = expectedEpoch ?? auth.accountSessionEpoch;
    final requestSerial = serial ?? ++_historyLoadSerial;
    if (requestSerial != _historyLoadSerial) return;
    setState(() => _isLoading = true);
    final items = await _repository.getHistory(userId: capturedUserId);
    if (!mounted || requestSerial != _historyLoadSerial) return;
    final currentAuth = context.read<AuthProvider>();
    if (currentAuth.accountSessionEpoch != capturedEpoch ||
        currentAuth.user?.id.toString() != capturedUserId) {
      return;
    }
    setState(() {
      _allItems = items;
      _isLoading = false;
    });
  }

  List<BrowsingHistoryItem> get _filteredItems {
    final currentFilter = _tabs[_tabController.index].type;
    if (currentFilter == null) return _allItems;
    return _allItems.where((i) => i.type == currentFilter).toList();
  }

  Future<void> _deleteItem(BrowsingHistoryItem item) async {
    final auth = context.read<AuthProvider>();
    final userId = auth.user?.id.toString();
    final epoch = auth.accountSessionEpoch;
    await _repository.removeItem(item.id, userId: userId);
    if (!mounted) return;
    final currentAuth = context.read<AuthProvider>();
    if (currentAuth.accountSessionEpoch != epoch ||
        currentAuth.user?.id.toString() != userId) {
      return;
    }
    await _loadHistory(userId: userId, expectedEpoch: epoch);
  }

  Future<void> _confirmClearAll() async {
    final auth = context.read<AuthProvider>();
    final userId = auth.user?.id.toString();
    final epoch = auth.accountSessionEpoch;
    final tokens = AppThemeTokens.of(context);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: tokens.surface,
        title: Text('清空浏览记录', style: TextStyle(color: tokens.textPrimary)),
        content: Text(
          '确定要清空所有浏览记录吗？此操作无法撤销。',
          style: TextStyle(color: tokens.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('取消', style: TextStyle(color: tokens.textSecondary)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: tokens.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认清空'),
          ),
        ],
      ),
    );

    if (confirm == true && mounted) {
      final currentAuth = context.read<AuthProvider>();
      if (currentAuth.accountSessionEpoch != epoch ||
          currentAuth.user?.id.toString() != userId) {
        return;
      }
      await _repository.clearAll(userId: userId);
      await _loadHistory(userId: userId, expectedEpoch: epoch);
    }
  }

  void _openDetail(BrowsingHistoryItem item) {
    if (item.type == BrowsingHistoryType.campusNews) {
      final articleId = int.tryParse(item.targetId) ?? 0;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => CampusArticleDetailScreen(
            summary: CampusArticleSummary(
              id: articleId,
              title: item.titleSnapshot,
              authorDepartment: item.authorSnapshot ?? '',
            ),
          ),
        ),
      ).then((_) => _loadHistory());
    } else {
      final postId = int.tryParse(item.targetId) ?? 0;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => PostDetailScreen(postId: postId),
        ),
      ).then((_) => _loadHistory());
    }
  }

  String _formatDateHeader(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final itemDate = DateTime(date.year, date.month, date.day);

    final diffDays = today.difference(itemDate).inDays;
    if (diffDays == 0) return '今天';
    if (diffDays == 1) return '昨天';
    if (diffDays < 7) return '$diffDays天前';
    return DateFormat('yyyy年MM月dd日').format(date);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);

    return Scaffold(
      backgroundColor: tokens.background,
      appBar: AppBar(
        title: Text(
          '浏览记录',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: tokens.textPrimary,
          ),
        ),
        backgroundColor: tokens.surface,
        elevation: 0,
        actions: [
          if (_allItems.isNotEmpty)
            IconButton(
              icon: Icon(Icons.delete_sweep_outlined,
                  color: tokens.textSecondary),
              tooltip: '清空记录',
              onPressed: _confirmClearAll,
            ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(44),
          child: Container(
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: tokens.surface,
              border: Border(bottom: BorderSide(color: tokens.divider)),
            ),
            child: TabBar(
              controller: _tabController,
              isScrollable: false,
              indicatorColor: tokens.primary,
              labelColor: tokens.primary,
              unselectedLabelColor: tokens.textSecondary,
              labelStyle:
                  const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
              unselectedLabelStyle: const TextStyle(fontSize: 14),
              tabs: _tabs.map((t) => Tab(text: t.label)).toList(),
            ),
          ),
        ),
      ),
      body: _isLoading
          ? Center(child: CircularProgressIndicator(color: tokens.primary))
          : _buildList(tokens),
    );
  }

  Widget _buildList(AppThemeTokens tokens) {
    final items = _filteredItems;

    if (items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.history_toggle_off_rounded,
                size: 64, color: tokens.textDisabled),
            const SizedBox(height: 16),
            Text(
              '暂无浏览记录',
              style: TextStyle(fontSize: 15, color: tokens.textSecondary),
            ),
          ],
        ),
      );
    }

    // 按日期分组
    final grouped = <String, List<BrowsingHistoryItem>>{};
    for (final item in items) {
      final header = _formatDateHeader(item.viewedAt);
      grouped.putIfAbsent(header, () => []).add(item);
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 12),
      itemCount: grouped.keys.length,
      itemBuilder: (context, groupIdx) {
        final dateHeader = grouped.keys.elementAt(groupIdx);
        final groupItems = grouped[dateHeader]!;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 6),
              child: Text(
                dateHeader,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: tokens.textSecondary,
                ),
              ),
            ),
            ...groupItems.map((item) => _buildItemTile(item, tokens)),
          ],
        );
      },
    );
  }

  Widget _buildItemTile(BrowsingHistoryItem item, AppThemeTokens tokens) {
    final timeStr = DateFormat('HH:mm').format(item.viewedAt);
    final isNews = item.type == BrowsingHistoryType.campusNews;

    return Dismissible(
      key: Key(item.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        color: tokens.error,
        child: const Icon(Icons.delete_outline, color: Colors.white),
      ),
      onDismissed: (_) => _deleteItem(item),
      child: InkWell(
        onTap: () => _openDetail(item),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            border:
                Border(bottom: BorderSide(color: tokens.divider, width: 0.5)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 类型标签（Section 30: 必须直接显示文字，不能只靠图标区别）
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: isNews
                      ? (tokens.isDark
                          ? const Color(0xFF1E3A34)
                          : const Color(0xFFE8F5F1))
                      : (tokens.isDark
                          ? const Color(0xFF2C253B)
                          : const Color(0xFFF3EBF9)),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  item.type.label,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: isNews
                        ? tokens.primary
                        : (tokens.isDark
                            ? const Color(0xFFC084FC)
                            : const Color(0xFF7C3AED)),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              // 标题与附加信息
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.titleSnapshot,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                        color: tokens.textPrimary,
                        height: 1.3,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        if (item.authorSnapshot != null &&
                            item.authorSnapshot!.isNotEmpty) ...[
                          Text(
                            item.authorSnapshot!,
                            style: TextStyle(
                              fontSize: 12,
                              color: tokens.textSecondary,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text('·',
                              style: TextStyle(
                                  color: tokens.textDisabled, fontSize: 12)),
                          const SizedBox(width: 8),
                        ],
                        Text(
                          timeStr,
                          style: TextStyle(
                            fontSize: 12,
                            color: tokens.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: Icon(Icons.close_rounded,
                    size: 18, color: tokens.textDisabled),
                tooltip: '删除此条记录',
                onPressed: () => _deleteItem(item),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
