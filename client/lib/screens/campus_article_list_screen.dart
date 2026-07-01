import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../main.dart';
import '../models/campus_article.dart';
import '../services/campus_article_service.dart';
import '../utils/app_feedback.dart';
import 'campus_article_detail_screen.dart';

/// 全部校园资讯列表页。
///
/// 支持分类筛选（全部 / 教务通知 / 教务公告）和分页加载。
class CampusArticleListScreen extends StatefulWidget {
  /// 用于测试注入的可选 Service。生产环境传 null，内部使用 getSharedDio()。
  final CampusArticleService? service;

  const CampusArticleListScreen({super.key, this.service});

  @override
  State<CampusArticleListScreen> createState() =>
      _CampusArticleListScreenState();
}

/// 分类筛选选项。
class _CategoryFilter {
  final String label;
  final String? slug;

  const _CategoryFilter({required this.label, this.slug});
}

const _categoryFilters = [
  _CategoryFilter(label: '全部'),
  _CategoryFilter(label: '教务通知', slug: 'jwtz'),
  _CategoryFilter(label: '教务公告', slug: 'jwgg'),
  _CategoryFilter(label: '比赛通知', slug: 'competition'),
];

class _CampusArticleListScreenState extends State<CampusArticleListScreen> {
  late CampusArticleService _service;
  late ScrollController _scrollController;

  // 当前选中的分类
  int _selectedFilterIndex = 0;

  // 文章列表
  List<CampusArticleSummary> _articles = [];
  int _currentPage = 1;
  bool _hasMore = true;

  // 状态
  bool _isLoading = false; // 首次加载 / 刷新
  bool _isLoadingMore = false; // 分页加载
  String? _errorMessage; // 首次加载错误（分页错误用 snackbar）

  // 防止分类切换后旧请求覆盖新状态
  int _requestToken = 0;

  @override
  void initState() {
    super.initState();
    _service = widget.service ?? CampusArticleService(getSharedDio());
    _scrollController = ScrollController();
    _scrollController.addListener(_onScroll);
    _loadFirstPage();
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
            _scrollController.position.maxScrollExtent - 200 &&
        !_isLoading &&
        !_isLoadingMore &&
        _hasMore &&
        _errorMessage == null) {
      _loadMore();
    }
  }

  /// 当前分类的 slug。
  String? get _currentCategorySlug =>
      _categoryFilters[_selectedFilterIndex].slug;

  /// 加载第一页（首次加载或刷新）。
  Future<void> _loadFirstPage() async {
    final token = ++_requestToken;
    setState(() {
      _isLoading = true;
      _isLoadingMore = false; // 切换分类时清除可能残留的分页加载标记
      _errorMessage = null;
      _articles = [];
      _currentPage = 1;
      _hasMore = true;
    });

    try {
      final page = await _service.getArticles(
        page: 1,
        categorySlug: _currentCategorySlug,
      );
      if (!mounted || token != _requestToken) return;
      setState(() {
        _articles = page.items;
        _hasMore = page.hasMore;
        _isLoading = false;
      });
    } on CampusArticleServiceException catch (e) {
      if (!mounted || token != _requestToken) return;
      setState(() {
        _errorMessage = e.message;
        _isLoading = false;
      });
    } on DioException catch (e) {
      if (!mounted || token != _requestToken) return;
      setState(() {
        _errorMessage = AppFeedback.dioErrorMessage(
          e,
          serviceName: '校园资讯',
          fallback: '加载失败',
        );
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted || token != _requestToken) return;
      setState(() {
        _errorMessage = '加载失败';
        _isLoading = false;
      });
    }
  }

  /// 加载下一页。
  Future<void> _loadMore() async {
    if (_isLoadingMore || !_hasMore) return;

    final token = _requestToken;
    setState(() {
      _isLoadingMore = true;
    });

    try {
      final nextPage = _currentPage + 1;
      final page = await _service.getArticles(
        page: nextPage,
        categorySlug: _currentCategorySlug,
      );
      if (!mounted || token != _requestToken) {
        // 旧请求被分类切换作废，不修改状态
        return;
      }

      // 按 id 去重
      final existingIds = _articles.map((a) => a.id).toSet();
      final newItems =
          page.items.where((a) => !existingIds.contains(a.id)).toList();

      setState(() {
        _articles.addAll(newItems);
        _currentPage = nextPage;
        _hasMore = page.hasMore;
        _isLoadingMore = false;
      });
    } on DioException catch (e) {
      if (!mounted || token != _requestToken) return;
      setState(() {
        _isLoadingMore = false;
      });
      if (mounted) {
        AppFeedback.showSnackBar(
          context,
          AppFeedback.dioErrorMessage(
            e,
            serviceName: '校园资讯',
            fallback: '加载更多失败',
          ),
          isError: true,
        );
      }
    } catch (e) {
      if (!mounted || token != _requestToken) return;
      setState(() {
        _isLoadingMore = false;
      });
    }
  }

  /// 切换分类筛选。
  void _switchFilter(int index) {
    if (index == _selectedFilterIndex) return;
    HapticFeedback.selectionClick();
    setState(() {
      _selectedFilterIndex = index;
    });
    _loadFirstPage();
  }

  /// 打开文章详情。
  void _openDetail(CampusArticleSummary summary) {
    HapticFeedback.selectionClick();
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CampusArticleDetailScreen(summary: summary),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      backgroundColor:
          isDark ? const Color(0xFF101219) : const Color(0xFFF8F7FC),
      appBar: AppBar(
        title: const Text('校园资讯'),
        backgroundColor: isDark ? const Color(0xFF1B1E28) : Colors.white,
        foregroundColor: isDark ? Colors.white : const Color(0xFF20212B),
        elevation: 0,
        scrolledUnderElevation: 0.5,
      ),
      body: SafeArea(
        child: Column(
          children: [
            // 副标题
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '校内通知与竞赛信息',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: isDark ? Colors.white54 : Colors.black54,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            // 分类筛选
            _buildFilterTabs(isDark),
            const SizedBox(height: 8),
            // 列表
            Expanded(
              child: _buildListContent(isDark),
            ),
          ],
        ),
      ),
    );
  }

  // ── 分类筛选标签 ───────────────────────────────────────────────

  Widget _buildFilterTabs(bool isDark) {
    final primary = Theme.of(context).colorScheme.primary;

    return SizedBox(
      height: 38,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: _categoryFilters.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final filter = _categoryFilters[index];
          final isSelected = index == _selectedFilterIndex;

          return GestureDetector(
            onTap: () => _switchFilter(index),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: isSelected
                    ? primary
                    : (isDark ? const Color(0xFF1B1E28) : Colors.white),
                borderRadius: BorderRadius.circular(99),
                border: Border.all(
                  color: isSelected
                      ? primary
                      : (isDark ? Colors.white10 : const Color(0xFFEDEBF3)),
                ),
              ),
              alignment: Alignment.center,
              child: Text(
                filter.label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: isSelected
                      ? Colors.white
                      : (isDark ? Colors.white70 : const Color(0xFF555666)),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  // ── 列表内容 ───────────────────────────────────────────────────

  Widget _buildListContent(bool isDark) {
    // 首次加载中
    if (_isLoading) {
      return _buildSkeletonList(isDark);
    }

    // 首次加载失败
    if (_errorMessage != null) {
      return _buildErrorState(isDark, _errorMessage!);
    }

    // 空数据
    if (_articles.isEmpty) {
      return _buildEmptyState(isDark);
    }

    // 正常列表
    return RefreshIndicator(
      onRefresh: _loadFirstPage,
      child: ListView.builder(
        controller: _scrollController,
        physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics(),
        ),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
        itemCount: _articles.length + 1, // +1 for loading more / end indicator
        itemBuilder: (context, index) {
          if (index == _articles.length) {
            return _buildLoadMoreIndicator(isDark);
          }
          return _buildArticleItem(isDark, _articles[index]);
        },
      ),
    );
  }

  Widget _buildArticleItem(bool isDark, CampusArticleSummary article) {
    final primary = Theme.of(context).colorScheme.primary;
    // 比赛通知用橙金色，教务通知/公告保持主色
    final tagColor = article.source == 'cxcy'
        ? const Color(0xFFE89B30)
        : primary;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: isDark ? const Color(0xFF1B1E28) : Colors.white,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: () => _openDetail(article),
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: isDark ? Colors.white10 : const Color(0xFFEDEBF3),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 分类 + 日期
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: tagColor.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        article.category.isNotEmpty ? article.category : '校园资讯',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: tagColor,
                        ),
                      ),
                    ),
                    const Spacer(),
                    Text(
                      article.shortDate,
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark ? Colors.white38 : Colors.black45,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                // 标题（最多两行）
                Text(
                  article.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    height: 1.4,
                    fontWeight: FontWeight.w600,
                    color: isDark ? Colors.white : const Color(0xFF292A35),
                  ),
                ),
                const SizedBox(height: 8),
                // 部门 · 附件状态
                Row(
                  children: [
                    if (article.authorDepartment.isNotEmpty) ...[
                      Icon(
                        Icons.badge_outlined,
                        size: 13,
                        color: isDark ? Colors.white38 : Colors.black45,
                      ),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          article.authorDepartment,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: isDark ? Colors.white38 : Colors.black45,
                          ),
                        ),
                      ),
                    ],
                    if (article.authorDepartment.isNotEmpty &&
                        article.hasAttachment) ...[
                      Text(
                        ' · ',
                        style: TextStyle(
                          fontSize: 12,
                          color: isDark ? Colors.white24 : Colors.black26,
                        ),
                      ),
                    ],
                    if (article.hasAttachment) ...[
                      Icon(
                        Icons.attach_file_rounded,
                        size: 13,
                        color: isDark ? Colors.white38 : Colors.black45,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '含附件',
                        style: TextStyle(
                          fontSize: 12,
                          color: isDark ? Colors.white38 : Colors.black45,
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── 骨架屏 ─────────────────────────────────────────────────────

  Widget _buildSkeletonList(bool isDark) {
    final shimmerColor = isDark ? Colors.white10 : const Color(0xFFEDEBF3);
    return ListView.builder(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
      itemCount: 6,
      itemBuilder: (context, index) {
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Container(
            height: 110,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF1B1E28) : Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: shimmerColor),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 60,
                  height: 16,
                  decoration: BoxDecoration(
                    color: shimmerColor,
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
                const SizedBox(height: 10),
                Container(
                  height: 16,
                  decoration: BoxDecoration(
                    color: shimmerColor,
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
                const SizedBox(height: 6),
                Container(
                  width: 200,
                  height: 16,
                  decoration: BoxDecoration(
                    color: shimmerColor,
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ── 空状态 ─────────────────────────────────────────────────────

  Widget _buildEmptyState(bool isDark) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.inbox_rounded,
            size: 56,
            color: isDark ? Colors.white24 : Colors.black26,
          ),
          const SizedBox(height: 12),
          Text(
            '暂无校园资讯',
            style: TextStyle(
              fontSize: 15,
              color: isDark ? Colors.white38 : Colors.black45,
            ),
          ),
          const SizedBox(height: 16),
          TextButton(
            onPressed: _loadFirstPage,
            child: const Text('刷新'),
          ),
        ],
      ),
    );
  }

  // ── 错误状态 ───────────────────────────────────────────────────

  Widget _buildErrorState(bool isDark, String message) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.cloud_off_rounded,
              size: 56,
              color: isDark ? Colors.white24 : Colors.black26,
            ),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: isDark ? Colors.white54 : Colors.black54,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.tonal(
              onPressed: _loadFirstPage,
              child: const Text('点击重试'),
            ),
          ],
        ),
      ),
    );
  }

  // ── 加载更多 / 列表底部 ────────────────────────────────────────

  Widget _buildLoadMoreIndicator(bool isDark) {
    if (_isLoadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
        ),
      );
    }

    if (!_hasMore) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: Text(
            '没有更多了',
            style: TextStyle(
              fontSize: 12.5,
              color: isDark ? Colors.white24 : Colors.black26,
            ),
          ),
        ),
      );
    }

    return const SizedBox.shrink();
  }
}
