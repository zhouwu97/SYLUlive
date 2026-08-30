import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:provider/provider.dart';

import '../models/admin_user_summary.dart';
import '../providers/auth_provider.dart';
import '../widgets/cached_avatar.dart';
import '../theme/app_colors.dart';
import '../theme/app_radius.dart';
import '../theme/app_spacing.dart';
import '../theme/app_text_styles.dart';
import '../widgets/app_page_app_bar.dart';
import '../config/api_constants.dart';

class AdminCandidatesScreen extends StatefulWidget {
  const AdminCandidatesScreen({super.key});

  @override
  State<AdminCandidatesScreen> createState() => _AdminCandidatesScreenState();
}

class _AdminCandidatesScreenState extends State<AdminCandidatesScreen> {
  static const int _pageSize = 20;

  List<AdminUserSummary> _candidates = [];
  bool _initialLoading = false;
  bool _loadingMore = false;
  bool _refreshing = false;
  bool _hasMore = true;
  int _page = 1;
  String _currentQuery = '';
  bool _hasSearched = false;
  String? _errorMessage;
  final _searchController = TextEditingController();
  final _scrollController = ScrollController();

  int? _totalUsers;
  int? _eduUsers;
  int? _otherUsers;
  int? _eligibleUsers;
  bool _statsLoading = false;
  String? _statsError;
  String? _loadMoreError;
  int _candidateRequestGeneration = 0;
  int _statsRequestGeneration = 0;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _fetchStats();
      _loadCandidates();
    });
  }

  Future<void> _fetchStats() async {
    if (!mounted) return;
    final requestGeneration = ++_statsRequestGeneration;
    setState(() {
      _statsLoading = true;
      _statsError = null;
    });
    try {
      final dio = context.read<AuthProvider>().dio;
      final res = await dio.get('/admin/candidates/stats');
      if (!mounted || requestGeneration != _statsRequestGeneration) return;
      final data = res.data;
      if (data is! Map) throw const FormatException('候选人统计响应格式错误');

      int? readCount(Object? raw) {
        if (raw is num) return raw.toInt();
        return int.tryParse(raw?.toString() ?? '');
      }

      setState(() {
        _totalUsers = readCount(data['total']);
        _eduUsers = readCount(data['edu']);
        _otherUsers = readCount(data['other']);
        _eligibleUsers = readCount(data['eligible']);
        _statsLoading = false;
      });
    } catch (e) {
      if (!mounted || requestGeneration != _statsRequestGeneration) return;
      debugPrint('[AdminCandidates] stats request failed: $e');
      setState(() {
        _statsLoading = false;
        _statsError = '统计暂不可用';
      });
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  List<AdminUserSummary> _decodeCandidates(List<dynamic> items) {
    return items
        .whereType<Map>()
        .map(
          (value) => AdminUserSummary.fromJson(
            Map<String, dynamic>.from(value),
          ),
        )
        .toList();
  }

  Future<void> _loadCandidates({String? keyword, bool append = false}) async {
    if (!mounted) return;
    final q = keyword ?? _currentQuery;
    _currentQuery = q;
    final requestGeneration = ++_candidateRequestGeneration;

    setState(() {
      if (append) {
        _loadingMore = true;
        _loadMoreError = null;
      } else {
        _initialLoading = _candidates.isEmpty && !_refreshing;
        _hasSearched = q.isNotEmpty;
        _errorMessage = null;
        _loadMoreError = null;
        _page = 1;
        _hasMore = true;
      }
    });

    try {
      final dio = context.read<AuthProvider>().dio;
      final res = await dio.get(
        '/admin/candidates',
        queryParameters: {
          'page': append ? _page + 1 : 1,
          'page_size': _pageSize,
          if (q.isNotEmpty) 'q': q,
        },
      );

      if (!mounted ||
          requestGeneration != _candidateRequestGeneration ||
          _currentQuery != q) {
        return;
      }

      final data = res.data;
      final rawItems = data is Map ? data['items'] : null;
      final items = rawItems is List ? rawItems : const <dynamic>[];
      final hasMore = (data is Map ? data['has_more'] as bool? : null) ?? false;

      setState(() {
        if (append) {
          _candidates = [..._candidates, ..._decodeCandidates(items)];
          _page += 1;
        } else {
          _candidates = _decodeCandidates(items);
        }
        _hasMore = hasMore;
        _initialLoading = false;
        _refreshing = false;
        _loadingMore = false;
        _loadMoreError = null;
      });
    } catch (e) {
      if (!mounted ||
          requestGeneration != _candidateRequestGeneration ||
          _currentQuery != q) {
        return;
      }
      debugPrint('[AdminCandidates] candidate request failed: $e');
      setState(() {
        _initialLoading = false;
        _refreshing = false;
        _loadingMore = false;
        if (append) {
          _loadMoreError = '加载更多失败';
        } else if (_candidates.isEmpty) {
          _errorMessage = '候选人加载失败，请稍后重试';
        }
      });
      if (append || _candidates.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(append ? '加载更多失败' : '刷新失败'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (position.pixels >= position.maxScrollExtent - 200) {
      _loadMore();
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || _refreshing || _initialLoading || !_hasMore) return;
    await _loadCandidates(append: true);
  }

  Future<void> _searchCandidates() async {
    await _loadCandidates(keyword: _searchController.text.trim());
  }

  Future<void> _refreshCandidates() async {
    setState(() {
      _refreshing = true;
      _errorMessage = null;
    });
    await Future.wait([_fetchStats(), _loadCandidates()]);
  }

  Future<void> _inviteAdmin(AdminUserSummary candidate) async {
    final dio = context.read<AuthProvider>().dio;
    final messenger = ScaffoldMessenger.of(context);
    final reason = await _showReasonDialog(
      title: '邀请 ${candidate.nickname} 成为管理员',
      label: '给候选人的邀请理由',
      hint: '例如：社区贡献活跃、处理问题客观，希望邀请你参与管理',
      helperText: '该用户会看到这段文字，并决定是否接受邀请。',
      confirmText: '发送邀请',
    );
    if (!mounted || reason == null) return;

    try {
      await dio.post(
        '/admin/invite/${candidate.id}',
        data: {'reason': reason},
      );
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(
          content: Text('邀请已发送，用户同意后进入管理员待办'),
          backgroundColor: Colors.green,
        ),
      );
      setState(() {
        _candidates.removeWhere((item) => item.id == candidate.id);
        if (_eligibleUsers != null && _eligibleUsers! > 0) {
          _eligibleUsers = _eligibleUsers! - 1;
        }
      });
    } on DioException catch (e) {
      if (!mounted) return;
      String msg = '邀请失败';
      if (e.response?.data is Map) {
        final data = e.response!.data as Map;
        msg = (data['message'] ?? data['error'])?.toString() ?? msg;
      }
      messenger.showSnackBar(
        SnackBar(content: Text(msg), backgroundColor: Colors.red),
      );
    }
  }

  Future<String?> _showReasonDialog({
    required String title,
    required String label,
    required String hint,
    required String helperText,
    required String confirmText,
  }) async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      useRootNavigator: false,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          maxLines: 4,
          decoration: InputDecoration(
            labelText: label,
            hintText: hint,
            helperText: helperText,
            helperMaxLines: 3,
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final reason = controller.text.trim();
              if (reason.isEmpty) return;
              Navigator.pop(ctx, reason);
            },
            child: Text(confirmText),
          ),
        ],
      ),
    );
  }

  Widget _buildStatItem(String label, int? value, bool isDark) {
    return Expanded(
      child: Column(
        children: [
          Text(
            value?.toString() ?? '--',
            style: AppTextStyles.titleMedium.copyWith(
              fontSize: 20,
              color: isDark ? Colors.white : AppColors.textPrimaryLight,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            label,
            style: AppTextStyles.labelMedium.copyWith(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.62)
                  : AppColors.textSecondaryLight,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatsCard(bool isDark) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.lg,
        AppSpacing.xs,
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: isDark
                ? const [Color(0xFF173B36), AppColors.surfaceSecondaryDark]
                : const [Color(0xFFEAF6F3), Colors.white],
          ),
          borderRadius: BorderRadius.circular(AppRadius.lg),
          border: Border.all(
            color: isDark
                ? Colors.white.withValues(alpha: 0.08)
                : AppColors.borderNormalLight,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
          child: Column(
            children: [
              Row(
                children: [
                  _buildStatItem(
                    '总用户',
                    _statsError == null ? _totalUsers : null,
                    isDark,
                  ),
                  _buildStatDivider(isDark),
                  _buildStatItem(
                    '教务账号',
                    _statsError == null ? _eduUsers : null,
                    isDark,
                  ),
                  _buildStatDivider(isDark),
                  _buildStatItem(
                    '其他',
                    _statsError == null ? _otherUsers : null,
                    isDark,
                  ),
                ],
              ),
              if (_statsLoading) ...[
                const SizedBox(height: AppSpacing.sm),
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ],
              if (_statsError != null) ...[
                const SizedBox(height: AppSpacing.sm),
                Text(
                  _statsError!,
                  style: AppTextStyles.labelMedium.copyWith(
                    color: isDark ? Colors.orange[200] : Colors.orange[800],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatDivider(bool isDark) {
    return Container(
      width: 1,
      height: 34,
      color: isDark
          ? Colors.white.withValues(alpha: 0.1)
          : AppColors.borderSubtleLight,
    );
  }

  Widget _buildSearchField(bool isDark) {
    final hasKeyword = _searchController.text.trim().isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.sm,
        AppSpacing.lg,
        AppSpacing.sm,
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: isDark
              ? AppColors.surfaceSecondaryDark
              : AppColors.surfaceSecondaryLight,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(
            color: isDark
                ? Colors.white.withValues(alpha: 0.1)
                : AppColors.borderSubtleLight,
          ),
        ),
        child: TextField(
          controller: _searchController,
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _searchCandidates(),
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            prefixIcon: Icon(
              Icons.search_rounded,
              color: isDark
                  ? Colors.white.withValues(alpha: 0.55)
                  : AppColors.textSecondaryLight,
            ),
            hintText: '搜索用户 ID、学号/账号或昵称',
            hintStyle: TextStyle(
              fontSize: 13,
              color: isDark
                  ? Colors.white.withValues(alpha: 0.45)
                  : AppColors.textSecondaryLight,
            ),
            border: InputBorder.none,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.sm,
              vertical: AppSpacing.md,
            ),
            suffixIcon: IconButton(
              tooltip: hasKeyword ? '清除搜索' : '搜索候选人',
              icon: Icon(
                hasKeyword ? Icons.close_rounded : Icons.arrow_forward_rounded,
                color: hasKeyword
                    ? (isDark
                        ? Colors.white.withValues(alpha: 0.58)
                        : AppColors.textSecondaryLight)
                    : AppColors.brandPrimary,
              ),
              onPressed: hasKeyword
                  ? () {
                      _searchController.clear();
                      _loadCandidates(keyword: '');
                    }
                  : _searchCandidates,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStateCard({
    required bool isDark,
    required IconData icon,
    required String title,
    required String message,
    VoidCallback? onPressed,
  }) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 300),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: isDark
                    ? AppColors.brandPrimary.withValues(alpha: 0.16)
                    : AppColors.brandPrimary.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: AppColors.brandPrimary, size: 30),
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              title,
              textAlign: TextAlign.center,
              style: AppTextStyles.titleMedium.copyWith(
                color: isDark ? Colors.white : AppColors.textPrimaryLight,
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              message,
              textAlign: TextAlign.center,
              style: AppTextStyles.bodyMedium.copyWith(
                color: isDark
                    ? Colors.white.withValues(alpha: 0.58)
                    : AppColors.textSecondaryLight,
              ),
            ),
            if (onPressed != null) ...[
              const SizedBox(height: AppSpacing.lg),
              FilledButton.tonalIcon(
                onPressed: onPressed,
                style: FilledButton.styleFrom(
                  backgroundColor: isDark
                      ? AppColors.brandPrimary.withValues(alpha: 0.24)
                      : const Color(0xFFE5F4F1),
                  foregroundColor:
                      isDark ? const Color(0xFF8DE0D3) : AppColors.brandPrimary,
                ),
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('重新加载'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildCandidateCard(AdminUserSummary candidate, bool isDark) {
    final name = candidate.nickname.isEmpty ? '未知用户' : candidate.nickname;
    final surface = isDark
        ? AppColors.surfaceSecondaryDark
        : AppColors.surfaceSecondaryLight;

    return Card(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      elevation: 0,
      color: surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        side: BorderSide(
          color: isDark
              ? Colors.white.withValues(alpha: 0.08)
              : AppColors.borderSubtleLight,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          AppSpacing.md,
          AppSpacing.sm,
          AppSpacing.md,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CachedAvatar(
              imageUrl: candidate.avatar.isEmpty
                  ? null
                  : ApiConstants.fullUrl(candidate.avatar),
              fallbackText: name,
              radius: 22,
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: AppTextStyles.titleMedium.copyWith(
                            fontSize: 16,
                            color: isDark
                                ? Colors.white
                                : AppColors.textPrimaryLight,
                          ),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      _buildCandidateChip(isDark),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    candidate.publicIdLabel,
                    style: AppTextStyles.bodyMedium.copyWith(
                      color: isDark
                          ? Colors.white.withValues(alpha: 0.62)
                          : AppColors.textSecondaryLight,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    candidate.accountLabel,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyles.bodyMedium.copyWith(
                      color: isDark
                          ? Colors.white.withValues(alpha: 0.62)
                          : AppColors.textSecondaryLight,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xs),
              child: FilledButton(
                onPressed: () => _inviteAdmin(candidate),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(64, 44),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  backgroundColor: isDark
                      ? AppColors.brandPrimary.withValues(alpha: 0.24)
                      : const Color(0xFFE5F4F1),
                  foregroundColor:
                      isDark ? const Color(0xFF8DE0D3) : AppColors.brandPrimary,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                ),
                child: const Text('邀请'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCandidateChip(bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: isDark
            ? AppColors.brandPrimary.withValues(alpha: 0.16)
            : AppColors.brandPrimary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Text(
        '候选人',
        style: AppTextStyles.labelMedium.copyWith(
          color: isDark ? const Color(0xFF8DE0D3) : AppColors.brandPrimary,
        ),
      ),
    );
  }

  Widget _buildCandidatesBody(bool isDark) {
    final bottomPadding =
        MediaQuery.viewPaddingOf(context).bottom + AppSpacing.xxl;

    if (_initialLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_errorMessage != null) {
      return _buildStateScroll(
        isDark: isDark,
        bottomPadding: bottomPadding,
        child: _buildStateCard(
          isDark: isDark,
          icon: Icons.cloud_off_rounded,
          title: '候选人加载失败',
          message: '网络或服务暂时不可用，可以下拉刷新重试。',
          onPressed: _refreshCandidates,
        ),
      );
    }

    if (_candidates.isEmpty && !_loadingMore) {
      return _buildStateScroll(
        isDark: isDark,
        bottomPadding: bottomPadding,
        child: _buildStateCard(
          isDark: isDark,
          icon:
              _hasSearched ? Icons.person_search_rounded : Icons.group_outlined,
          title: _hasSearched ? '没有找到候选人' : '暂无候选人',
          message: _hasSearched ? '换一个用户 ID、学号或昵称试试。' : '符合条件的普通用户会显示在这里。',
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _refreshCandidates,
      child: Scrollbar(
        controller: _scrollController,
        thumbVisibility: true,
        child: ListView.builder(
          controller: _scrollController,
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          physics: const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics(),
          ),
          padding: EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.xs,
            AppSpacing.lg,
            bottomPadding,
          ),
          itemCount: _candidates.length + 1,
          itemBuilder: (context, index) {
            if (index == _candidates.length) {
              return _buildListFooter(isDark);
            }
            return _buildCandidateCard(_candidates[index], isDark);
          },
        ),
      ),
    );
  }

  Widget _buildListFooter(bool isDark) {
    if (_loadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2.4),
          ),
        ),
      );
    }
    if (_loadMoreError != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Center(
          child: TextButton.icon(
            onPressed: _loadMore,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: Text(_loadMoreError!),
          ),
        ),
      );
    }
    if (!_hasMore && _candidates.isNotEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Center(
          child: Text(
            '已显示全部符合条件候选人',
            style: AppTextStyles.labelMedium.copyWith(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.4)
                  : AppColors.textSecondaryLight.withValues(alpha: 0.7),
            ),
          ),
        ),
      );
    }
    return const SizedBox(height: 12);
  }

  Widget _buildEligibleHeader(bool isDark) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.xs,
        AppSpacing.lg,
        AppSpacing.xs,
      ),
      child: Row(
        children: [
          Text(
            '符合邀请条件',
            style: AppTextStyles.labelMedium.copyWith(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.62)
                  : AppColors.textSecondaryLight,
            ),
          ),
          const Spacer(),
          Text(
            '${_statsError == null ? _eligibleUsers?.toString() ?? '--' : '--'} 人',
            style: AppTextStyles.titleMedium.copyWith(
              fontSize: 15,
              color: AppColors.brandPrimary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStateScroll({
    required bool isDark,
    required double bottomPadding,
    required Widget child,
  }) {
    return RefreshIndicator(
      onRefresh: _refreshCandidates,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics(),
        ),
        padding: EdgeInsets.fromLTRB(
          AppSpacing.xxl,
          AppSpacing.section,
          AppSpacing.xxl,
          bottomPadding,
        ),
        children: [child],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: const AppPageAppBar(title: Text('管理员候选人')),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            _buildStatsCard(isDark),
            _buildSearchField(isDark),
            _buildEligibleHeader(isDark),
            Expanded(child: _buildCandidatesBody(isDark)),
          ],
        ),
      ),
    );
  }
}
