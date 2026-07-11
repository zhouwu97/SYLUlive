import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/team_recruitment_provider.dart';
import '../../providers/auth_provider.dart';
import '../../providers/theme_provider.dart';
import '../../widgets/team/team_recruitment_card.dart';
import 'my_team_recruitments_screen.dart';
import 'team_recruitment_create_screen.dart';
import 'team_recruitment_detail_screen.dart';

class TeamRecruitmentCenterScreen extends StatefulWidget {
  const TeamRecruitmentCenterScreen({super.key});

  @override
  State<TeamRecruitmentCenterScreen> createState() =>
      _TeamRecruitmentCenterScreenState();
}

class _TeamRecruitmentCenterScreenState
    extends State<TeamRecruitmentCenterScreen> {
  String? _category;
  String? _status = 'recruiting';
  final _searchController = TextEditingController();
  final _scrollController = ScrollController();
  Timer? _searchDebounce;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    _scrollController
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  Future<void> _load() => context.read<TeamRecruitmentProvider>().loadPublic(
        category: _category,
        status: _status,
        keyword: _searchController.text,
      );

  void _onScroll() {
    if (_scrollController.position.extentAfter < 320) {
      context.read<TeamRecruitmentProvider>().loadMorePublic();
    }
  }

  void _onSearchChanged(String _) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 350), _load);
  }

  Future<void> _openCreate(TeamRecruitmentProvider provider) async {
    if (!context.read<AuthProvider>().isLoggedIn) {
      Navigator.pushNamed(context, '/login');
      return;
    }
    if (provider.viewState == TeamFeedViewState.unavailable) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('组队服务尚未部署，请更新服务器后重试')),
      );
      return;
    }
    final created = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const TeamRecruitmentCreateScreen()),
    );
    if (created == true && mounted) {
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<TeamRecruitmentProvider>();
    final themeProvider = context.watch<ThemeProvider>();
    return Scaffold(
      backgroundColor: themeProvider.shouldShowCustomBackground
          ? Colors.transparent
          : themeProvider.cleanModePageBackground(Theme.of(context).brightness),
      appBar: AppBar(
        centerTitle: true,
        title: const Text('组队大厅',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 17)),
        actions: [
          TextButton.icon(
            onPressed: () {
              if (!context.read<AuthProvider>().isLoggedIn) {
                Navigator.pushNamed(context, '/login');
                return;
              }
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const MyTeamRecruitmentsScreen(),
                ),
              );
            },
            icon: const Icon(Icons.person_outline_rounded, size: 18),
            label: const Text('我的'),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openCreate(provider),
        icon: const Icon(Icons.add_rounded),
        label: const Text('发起组队'),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: CustomScrollView(
          controller: _scrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              sliver: SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _SearchBar(
                      controller: _searchController,
                      onChanged: _onSearchChanged,
                      onFilter: _showMoreStatus,
                    ),
                    const SizedBox(height: 12),
                    _CategoryTabs(
                      current: _category,
                      onChanged: (value) {
                        setState(() => _category = value);
                        _load();
                      },
                    ),
                    const SizedBox(height: 12),
                    _StatusSegment(
                      current: _status,
                      onChanged: (value) {
                        setState(() => _status = value);
                        _load();
                      },
                      onMore: _showMoreStatus,
                    ),
                    const SizedBox(height: 12),
                    _ResultSummary(
                      count: provider.publicTotal,
                      viewState: provider.viewState,
                      sort: provider.currentSort,
                      onSort: _showSort,
                    ),
                    if (provider.refreshWarning != null) ...[
                      const SizedBox(height: 10),
                      _RefreshWarning(
                        message: provider.refreshWarning!,
                        onRetry: _load,
                      ),
                    ],
                  ],
                ),
              ),
            ),
            _buildContent(provider),
            const SliverPadding(padding: EdgeInsets.only(bottom: 108)),
          ],
        ),
      ),
    );
  }

  Widget _buildContent(TeamRecruitmentProvider provider) {
    switch (provider.viewState) {
      case TeamFeedViewState.initial:
      case TeamFeedViewState.loading:
        return const SliverPadding(
          padding: EdgeInsets.fromLTRB(16, 14, 16, 0),
          sliver: _TeamFeedSkeleton(),
        );
      case TeamFeedViewState.empty:
        return SliverToBoxAdapter(
          child: _TeamFeedStateView(
            icon: Icons.groups_2_outlined,
            title: '还没有符合条件的组队',
            description: '这里暂时没有正在招募的队伍，\n可以发起第一条组队招募。',
            actionLabel: '发起组队',
            onAction: () => _openCreate(provider),
          ),
        );
      case TeamFeedViewState.unavailable:
        return SliverToBoxAdapter(
          child: _TeamFeedStateView(
            icon: Icons.rocket_launch_outlined,
            title: '组队服务暂未上线',
            description: kDebugMode
                ? '当前客户端已包含组队大厅，\nGET /api/team/recruitments · ${provider.publicStatusCode ?? 404}'
                : '当前客户端已包含组队大厅，\n服务器接口还没有完成部署。',
            actionLabel: '重新检测',
            onAction: _load,
          ),
        );
      case TeamFeedViewState.networkError:
        return SliverToBoxAdapter(
          child: _TeamFeedStateView(
            icon: Icons.wifi_off_rounded,
            title: '网络连接失败',
            description: '请检查网络后重新加载。',
            actionLabel: '重新加载',
            onAction: _load,
          ),
        );
      case TeamFeedViewState.serverError:
        return SliverToBoxAdapter(
          child: _TeamFeedStateView(
            icon: Icons.cloud_off_outlined,
            title: '组队服务暂时不可用',
            description: '服务器正在处理异常，请稍后重试。',
            actionLabel: '重新加载',
            onAction: _load,
          ),
        );
      case TeamFeedViewState.content:
        return SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          sliver: SliverList.separated(
            itemCount: provider.publicItems.length +
                (provider.isLoadingMore || provider.publicHasMore ? 1 : 0),
            itemBuilder: (_, index) {
              if (index >= provider.publicItems.length) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: provider.isLoadingMore
                        ? const CircularProgressIndicator()
                        : TextButton(
                            onPressed: provider.loadMorePublic,
                            child: const Text('加载更多'),
                          ),
                  ),
                );
              }
              final item = provider.publicItems[index];
              return TeamRecruitmentCard(
                recruitment: item,
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        TeamRecruitmentDetailScreen(recruitmentId: item.id),
                  ),
                ),
              );
            },
            separatorBuilder: (_, __) => const SizedBox(height: 12),
          ),
        );
    }
  }

  void _showMoreStatus() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            title: const Text('全部状态'),
            onTap: () => _selectMoreStatus(sheetContext, null),
          ),
          ListTile(
            title: const Text('已关闭'),
            onTap: () => _selectMoreStatus(sheetContext, 'closed'),
          ),
          ListTile(
            title: const Text('已截止'),
            onTap: () => _selectMoreStatus(sheetContext, 'expired'),
          ),
        ]),
      ),
    );
  }

  void _showSort() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          for (final option in const [
            ('推荐排序', 'recommended'),
            ('最新发布', 'latest'),
            ('临近截止', 'deadline')
          ])
            ListTile(
              title: Text(option.$1),
              trailing: context.read<TeamRecruitmentProvider>().currentSort ==
                      option.$2
                  ? const Icon(Icons.check_rounded)
                  : null,
              onTap: () {
                Navigator.pop(sheetContext);
                context.read<TeamRecruitmentProvider>().loadPublic(
                      category: _category,
                      status: _status,
                      keyword: _searchController.text,
                      sort: option.$2,
                    );
              },
            ),
        ]),
      ),
    );
  }

  void _selectMoreStatus(BuildContext sheetContext, String? status) {
    Navigator.pop(sheetContext);
    setState(() => _status = status);
    _load();
  }
}

class _CategoryTabs extends StatelessWidget {
  final String? current;
  final ValueChanged<String?> onChanged;
  const _CategoryTabs({required this.current, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    const values = [
      ('全部', null),
      ('竞赛', 'competition'),
      ('项目', 'project'),
      ('学习', 'study'),
      ('活动', 'activity'),
      ('其他', 'other'),
    ];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: values.map((value) {
          final selected = current == value.$2;
          return Padding(
            padding: const EdgeInsets.only(right: 6),
            child: InkWell(
              borderRadius: BorderRadius.circular(99),
              onTap: () => onChanged(value.$2),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
                decoration: BoxDecoration(
                  color:
                      selected ? const Color(0xFFE9E7FF) : Colors.transparent,
                  borderRadius: BorderRadius.circular(99),
                ),
                child: Text(value.$1,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                      color: selected
                          ? const Color(0xFF6257C7)
                          : Colors.grey.shade600,
                    )),
              ),
            ),
          );
        }).toList(growable: false),
      ),
    );
  }
}

class _StatusSegment extends StatelessWidget {
  final String? current;
  final ValueChanged<String?> onChanged;
  final VoidCallback onMore;
  const _StatusSegment({
    required this.current,
    required this.onChanged,
    required this.onMore,
  });

  @override
  Widget build(BuildContext context) {
    const values = [
      ('招募中', 'recruiting'),
      ('即将截止', 'deadline_soon'),
      ('已满员', 'full'),
    ];
    return Row(children: [
      Expanded(
        child: Container(
          height: 40,
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: const Color(0xFFF0EEF4),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: values.map((value) {
              final selected = current == value.$2;
              return Expanded(
                child: InkWell(
                  borderRadius: BorderRadius.circular(9),
                  onTap: () => onChanged(selected ? null : value.$2),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: selected
                          ? const Color(0xFFE9E7FF)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Text(value.$1,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight:
                              selected ? FontWeight.w800 : FontWeight.w600,
                          color: selected
                              ? const Color(0xFF6257C7)
                              : Colors.grey.shade600,
                        )),
                  ),
                ),
              );
            }).toList(growable: false),
          ),
        ),
      ),
      IconButton(
        tooltip: '更多筛选',
        onPressed: onMore,
        icon: const Icon(Icons.tune_rounded, size: 20),
      ),
    ]);
  }
}

class _ResultSummary extends StatelessWidget {
  final int count;
  final TeamFeedViewState viewState;
  final String sort;
  final VoidCallback onSort;
  const _ResultSummary(
      {required this.count,
      required this.viewState,
      required this.sort,
      required this.onSort});
  @override
  Widget build(BuildContext context) => Row(children: [
        Text(viewState == TeamFeedViewState.content ? '共 $count 个招募' : '组队招募',
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: Colors.grey.shade700)),
        const Spacer(),
        Icon(Icons.sort_rounded, size: 15, color: Colors.grey.shade500),
        const SizedBox(width: 3),
        InkWell(
            onTap: onSort,
            child: Text(
                const {
                      'recommended': '推荐排序',
                      'latest': '最新发布',
                      'deadline': '临近截止'
                    }[sort] ??
                    '推荐排序',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade500))),
      ]);
}

class _SearchBar extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onFilter;
  const _SearchBar(
      {required this.controller,
      required this.onChanged,
      required this.onFilter});
  @override
  Widget build(BuildContext context) => SizedBox(
        height: 44,
        child: TextField(
          controller: controller,
          onChanged: onChanged,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: '搜索竞赛、项目、技能或关键词',
            prefixIcon: const Icon(Icons.search_rounded),
            suffixIcon: IconButton(
                onPressed: onFilter, icon: const Icon(Icons.tune_rounded)),
            filled: true,
            fillColor: Theme.of(context).colorScheme.surfaceContainerLowest,
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide:
                    BorderSide(color: Colors.grey.withValues(alpha: 0.18))),
            enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide:
                    BorderSide(color: Colors.grey.withValues(alpha: 0.18))),
            contentPadding: EdgeInsets.zero,
          ),
        ),
      );
}

class _RefreshWarning extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _RefreshWarning({required this.message, required this.onRetry});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
            color: const Color(0xFFFFF4DE),
            borderRadius: BorderRadius.circular(10)),
        child: Row(children: [
          Expanded(child: Text(message, style: const TextStyle(fontSize: 12))),
          TextButton(onPressed: onRetry, child: const Text('重试'))
        ]),
      );
}

class _TeamFeedStateView extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;
  final String actionLabel;
  final VoidCallback onAction;
  const _TeamFeedStateView({
    required this.icon,
    required this.title,
    required this.description,
    required this.actionLabel,
    required this.onAction,
  });
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 48, 24, 0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 36, color: const Color(0xFF7C6FF0)),
          const SizedBox(height: 14),
          Text(title,
              style:
                  const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 7),
          Text(description,
              style: TextStyle(height: 1.5, color: Colors.grey.shade600)),
          const SizedBox(height: 16),
          OutlinedButton.icon(
              onPressed: onAction,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: Text(actionLabel)),
        ]),
      );
}

class _TeamFeedSkeleton extends StatelessWidget {
  const _TeamFeedSkeleton();
  @override
  Widget build(BuildContext context) => SliverList.separated(
        itemCount: 3,
        itemBuilder: (_, __) => Container(
          height: 162,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
              color: Colors.grey.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(18)),
          child: const _SkeletonLines(),
        ),
        separatorBuilder: (_, __) => const SizedBox(height: 12),
      );
}

class _SkeletonLines extends StatelessWidget {
  const _SkeletonLines();
  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _line(72),
          const SizedBox(height: 15),
          _line(190),
          const SizedBox(height: 10),
          _line(245),
          const Spacer(),
          _line(140),
        ],
      );
  Widget _line(double width) => Container(
      width: width,
      height: 12,
      decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(99)));
}
