import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/competition.dart';
import '../../providers/auth_provider.dart';
import '../../utils/app_feedback.dart';
import '../../widgets/competition/competition_admin_event_card.dart';
import '../../widgets/competition/competition_empty_state.dart';
import '../../widgets/competition/competition_ui_tokens.dart';
import 'competition_admin_import_screen.dart';
import 'competition_official_event_editor_screen.dart';

class CompetitionAdminCenterScreen extends StatefulWidget {
  const CompetitionAdminCenterScreen({super.key});

  @override
  State<CompetitionAdminCenterScreen> createState() =>
      _CompetitionAdminCenterScreenState();
}

class _CompetitionAdminCenterScreenState
    extends State<CompetitionAdminCenterScreen> {
  final _searchController = TextEditingController();
  late Dio _dio;

  List<CompetitionCategory> _categories = [];
  List<CompetitionEvent> _events = [];
  bool _loading = true;

  String _adminStatusFilter = 'all';
  String? _maintenanceFilter;
  String? _categorySlug;
  final Set<String> _recommendations = {};
  final Set<int> _selectedEventIds = {};
  bool _selectionMode = false;

  int _adminTotalCount = 0;
  int _adminDraftCount = 0;
  int _adminPublishedCount = 0;
  int _adminArchivedCount = 0;

  @override
  void initState() {
    super.initState();
    _dio = context.read<AuthProvider>().dio;
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _loading = true);
    try {
      final results = await Future.wait([
        _dio.get('/competitions/categories'),
        _dio.get(
          '/admin/competitions/events',
          queryParameters: {'page_size': 1},
        ),
        _dio.get(
          '/admin/competitions/events',
          queryParameters: {'status': 'draft', 'page_size': 1},
        ),
        _dio.get(
          '/admin/competitions/events',
          queryParameters: {'status': 'published', 'page_size': 1},
        ),
        _dio.get(
          '/admin/competitions/events',
          queryParameters: {'status': 'archived', 'page_size': 1},
        ),
        _dio.get('/admin/competitions/events', queryParameters: _queryParams()),
      ]);

      if (!mounted) return;
      final listData = results[5].data as Map<String, dynamic>;
      setState(() {
        _categories = ((results[0].data as List?) ?? [])
            .map((item) => CompetitionCategory.fromJson(item))
            .toList();
        _adminTotalCount = _totalFrom(results[1].data);
        _adminDraftCount = _totalFrom(results[2].data);
        _adminPublishedCount = _totalFrom(results[3].data);
        _adminArchivedCount = _totalFrom(results[4].data);
        _events = ((listData['items'] as List?) ?? [])
            .map((item) => CompetitionEvent.fromJson(item))
            .toList();
        _selectedEventIds.removeWhere(
          (id) => !_events.any((event) => event.id == id),
        );
        _loading = false;
      });
    } on DioException catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      AppFeedback.showSnackBar(
        context,
        AppFeedback.dioErrorMessage(e, fallback: '加载竞赛库管理失败'),
        isError: true,
      );
    }
  }

  Map<String, dynamic> _queryParams() {
    return {
      'page_size': 50,
      if (_searchController.text.trim().isNotEmpty)
        'keyword': _searchController.text.trim(),
      if (_adminStatusFilter != 'all') 'status': _adminStatusFilter,
      if (_maintenanceFilter != null) 'maintenance_status': _maintenanceFilter,
      if (_categorySlug != null) 'category_slug': _categorySlug,
      if (_recommendations.isNotEmpty)
        'recommendation_level': _recommendations.join(','),
    };
  }

  int _totalFrom(dynamic data) {
    if (data is Map && data['total'] is num) {
      return (data['total'] as num).toInt();
    }
    return 0;
  }

  String get _filterSummary {
    final parts = <String>[];
    if (_maintenanceFilter != null) {
      parts.add(_maintenanceLabel(_maintenanceFilter));
    }
    if (_categorySlug != null) {
      final category = _categories
          .where((item) => item.slug == _categorySlug)
          .cast<CompetitionCategory?>()
          .firstOrNull;
      if (category != null) parts.add(category.name);
    }
    parts.addAll(_recommendations.map((level) => '$level推荐'));
    if (parts.isEmpty) return '全部维护项';
    if (parts.length <= 3) return parts.join(' · ');
    return '已选 ${parts.length} 项';
  }

  int get _missingTimeCount {
    return _events
        .where(
          (event) =>
              event.registrationEnd == null &&
              event.registrationTimeText.trim().isEmpty &&
              event.eventTimeText.trim().isEmpty,
        )
        .length;
  }

  int get _needsReviewCount {
    return _events
        .where(
          (event) =>
              event.timeStatus == 'pending' ||
              event.schoolRecognitionStatus == 'pending',
        )
        .length;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final pageBg = CompetitionUiTokens.pageBg(isDark);

    return Scaffold(
      backgroundColor: pageBg,
      appBar: AppBar(
        backgroundColor: pageBg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        title: const Text(
          '竞赛库管理',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
        actions: [
          TextButton.icon(
            onPressed: _openAdminImport,
            icon: const Icon(Icons.auto_awesome_rounded, size: 18),
            label: const Text('AI导入'),
            style: TextButton.styleFrom(
              foregroundColor: CompetitionUiTokens.accent(isDark),
            ),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            _buildStats(isDark),
            _buildSearch(isDark),
            _buildAdminActions(isDark),
            _buildFilterRows(isDark),
            if (_selectionMode) _buildSelectionBar(isDark),
            _buildSectionTitle(isDark),
            _buildEventList(isDark),
          ],
        ),
      ),
    );
  }

  Widget _buildStats(bool isDark) {
    final items = [
      ('草稿', '$_adminDraftCount', () => _selectStatus('draft')),
      ('缺时间', '$_missingTimeCount', () => _selectMaintenance('time_pending')),
      ('已发布', '$_adminPublishedCount', () => _selectStatus('published')),
      ('待核验', '$_needsReviewCount', () => _selectMaintenance('stale')),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        CompetitionUiTokens.pagePadding,
        12,
        CompetitionUiTokens.pagePadding,
        14,
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: CompetitionUiTokens.cardDecoration(isDark),
        child: Row(
          children: [
            for (var i = 0; i < items.length; i++) ...[
              Expanded(
                child: InkWell(
                  onTap: items[i].$3,
                  borderRadius: BorderRadius.circular(8),
                  child: Column(
                    children: [
                      Text(
                        items[i].$2,
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w900,
                          color: CompetitionUiTokens.titleColor(isDark),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        items[i].$1,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: CompetitionUiTokens.subColor(isDark),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (i != items.length - 1)
                Container(
                  width: 1,
                  height: 30,
                  color: CompetitionUiTokens.borderColor(isDark),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSearch(bool isDark) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        CompetitionUiTokens.pagePadding,
        0,
        CompetitionUiTokens.pagePadding,
        12,
      ),
      child: Container(
        height: 46,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: CompetitionUiTokens.cardBg(isDark),
          borderRadius: BorderRadius.circular(CompetitionUiTokens.cardRadius),
          border: Border.all(color: CompetitionUiTokens.borderColor(isDark)),
        ),
        child: Row(
          children: [
            Icon(
              Icons.search_rounded,
              color: CompetitionUiTokens.subColor(isDark),
              size: 21,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _searchController,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _load(),
                decoration: InputDecoration(
                  hintText: '搜索比赛 / 专业方向 / 标签',
                  hintStyle: TextStyle(
                    color: CompetitionUiTokens.subColor(isDark),
                    fontSize: 14,
                  ),
                  border: InputBorder.none,
                  isCollapsed: true,
                ),
                style: TextStyle(
                  fontSize: 14,
                  color: CompetitionUiTokens.titleColor(isDark),
                ),
              ),
            ),
            if (_searchController.text.isNotEmpty)
              IconButton(
                visualDensity: VisualDensity.compact,
                onPressed: () {
                  _searchController.clear();
                  setState(() {});
                  _load();
                },
                icon: Icon(
                  Icons.close_rounded,
                  size: 18,
                  color: CompetitionUiTokens.subColor(isDark),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildAdminActions(bool isDark) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        CompetitionUiTokens.pagePadding,
        0,
        CompetitionUiTokens.pagePadding,
        12,
      ),
      child: Row(
        children: [
          Expanded(
            child: FilledButton.icon(
              onPressed: _openAdminImport,
              icon: const Icon(Icons.auto_awesome_rounded, size: 18),
              label: const Text('AI导入'),
              style: FilledButton.styleFrom(
                backgroundColor: CompetitionUiTokens.accent(isDark),
                foregroundColor: Colors.white,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _openAdminManualCreate,
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('新建'),
              style: OutlinedButton.styleFrom(
                foregroundColor: CompetitionUiTokens.titleColor(isDark),
                side:
                    BorderSide(color: CompetitionUiTokens.borderColor(isDark)),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () {
                setState(() {
                  _selectionMode = !_selectionMode;
                  if (!_selectionMode) _selectedEventIds.clear();
                });
              },
              icon: Icon(
                _selectionMode ? Icons.close_rounded : Icons.checklist_rounded,
                size: 18,
              ),
              label: Text(_selectionMode ? '取消' : '批量发布'),
              style: OutlinedButton.styleFrom(
                foregroundColor: _selectionMode
                    ? CompetitionUiTokens.dangerColor(isDark)
                    : CompetitionUiTokens.titleColor(isDark),
                side:
                    BorderSide(color: CompetitionUiTokens.borderColor(isDark)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterRows(bool isDark) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        CompetitionUiTokens.pagePadding,
        0,
        CompetitionUiTokens.pagePadding,
        14,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _statusChip('全部', 'all', isDark),
                const SizedBox(width: 8),
                _statusChip('草稿', 'draft', isDark),
                const SizedBox(width: 8),
                _statusChip('已发布', 'published', isDark),
                const SizedBox(width: 8),
                _statusChip('已归档', 'archived', isDark),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _softButton(
                icon: Icons.build_circle_outlined,
                label: '维护筛选',
                isDark: isDark,
                highlight: _maintenanceFilter != null,
                onTap: _openMaintenanceFilters,
              ),
              const SizedBox(width: 8),
              _softButton(
                icon: Icons.category_outlined,
                label: '分类筛选',
                isDark: isDark,
                highlight: _categorySlug != null,
                onTap: _openAdminFilters,
              ),
              const SizedBox(width: 8),
              _softButton(
                icon: Icons.star_border_rounded,
                label: '推荐等级',
                isDark: isDark,
                highlight: _recommendations.isNotEmpty,
                onTap: _openAdminFilters,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            _filterSummary,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: _filterSummary == '全部维护项'
                  ? CompetitionUiTokens.subColor(isDark)
                  : CompetitionUiTokens.accent(isDark),
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSelectionBar(bool isDark) {
    return Container(
      margin: const EdgeInsets.fromLTRB(
        CompetitionUiTokens.pagePadding,
        0,
        CompetitionUiTokens.pagePadding,
        16,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: CompetitionUiTokens.cardBg(isDark),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: CompetitionUiTokens.borderColor(isDark)),
      ),
      child: Row(
        children: [
          Text(
            '已选 ${_selectedEventIds.length} 项',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: CompetitionUiTokens.titleColor(isDark),
            ),
          ),
          const SizedBox(width: 16),
          TextButton(
            onPressed: () {
              setState(() {
                if (_selectedEventIds.length == _events.length) {
                  _selectedEventIds.clear();
                } else {
                  _selectedEventIds.addAll(_events.map((event) => event.id));
                }
              });
            },
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              foregroundColor: CompetitionUiTokens.accent(isDark),
            ),
            child: Text(
              _selectedEventIds.length == _events.length ? '取消全选' : '全选当前页',
            ),
          ),
          const Spacer(),
          if (_selectedEventIds.isNotEmpty)
            FilledButton.tonal(
              onPressed: () => _batchAction(
                '发布',
                (id) => _dio.post('/admin/competitions/events/$id/publish'),
              ),
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 16),
              ),
              child: const Text('发布'),
            ),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(bool isDark) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        CompetitionUiTokens.pagePadding,
        2,
        CompetitionUiTokens.pagePadding,
        12,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '维护列表',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w900,
              color: CompetitionUiTokens.titleColor(isDark),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '官方库 $_adminTotalCount 条，已归档 $_adminArchivedCount 条',
            style: TextStyle(
              fontSize: 13,
              color: CompetitionUiTokens.subColor(isDark),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEventList(bool isDark) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.only(top: 40),
        child: Center(
          child: CircularProgressIndicator(),
        ),
      );
    }
    if (_events.isEmpty) {
      return CompetitionEmptyState(
        title: '列表还没有内容',
        message: '可以 AI 导入或手动新建官方草稿。',
        primaryText: 'AI导入',
        onPrimaryTap: _openAdminImport,
        secondaryText: '新建比赛',
        onSecondaryTap: _openAdminManualCreate,
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: CompetitionUiTokens.pagePadding,
      ),
      child: Column(
        children: _events.map(_buildEventCard).toList(),
      ),
    );
  }

  Widget _buildEventCard(CompetitionEvent event) {
    return CompetitionAdminEventCard(
      event: event,
      selectionMode: _selectionMode,
      isSelected: _selectedEventIds.contains(event.id),
      onTap: () {
        if (_selectionMode) {
          setState(() {
            if (_selectedEventIds.contains(event.id)) {
              _selectedEventIds.remove(event.id);
            } else {
              _selectedEventIds.add(event.id);
            }
          });
        } else {
          _openAdminDetail(event);
        }
      },
      onEdit: () => _openAdminDetail(event),
      onPublish: event.status == 'draft'
          ? () => _singleAction(
                event.id,
                '发布',
                (id) => _dio.post('/admin/competitions/events/$id/publish'),
              )
          : null,
      onArchive: event.status != 'archived'
          ? () => _singleAction(
                event.id,
                '归档',
                (id) => _dio.post('/admin/competitions/events/$id/archive'),
              )
          : null,
    );
  }

  Widget _statusChip(String label, String value, bool isDark) {
    final selected = _adminStatusFilter == value;
    return Material(
      color: selected
          ? CompetitionUiTokens.titleColor(isDark)
          : Colors.transparent,
      shape: StadiumBorder(
        side: BorderSide(
          color: selected
              ? Colors.transparent
              : CompetitionUiTokens.borderColor(isDark),
        ),
      ),
      child: InkWell(
        onTap: () => _selectStatus(value),
        customBorder: const StadiumBorder(),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
              color: selected
                  ? CompetitionUiTokens.pageBg(isDark)
                  : CompetitionUiTokens.titleColor(isDark),
            ),
          ),
        ),
      ),
    );
  }

  Widget _softButton({
    required IconData icon,
    required String label,
    required bool isDark,
    required bool highlight,
    required VoidCallback onTap,
  }) {
    return Material(
      color: highlight
          ? CompetitionUiTokens.titleColor(isDark)
          : Colors.transparent,
      shape: StadiumBorder(
        side: BorderSide(
          color: highlight
              ? Colors.transparent
              : CompetitionUiTokens.borderColor(isDark),
        ),
      ),
      child: InkWell(
        onTap: onTap,
        customBorder: const StadiumBorder(),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 16,
                color: highlight
                    ? CompetitionUiTokens.pageBg(isDark)
                    : CompetitionUiTokens.titleColor(isDark),
              ),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: highlight ? FontWeight.w600 : FontWeight.normal,
                  color: highlight
                      ? CompetitionUiTokens.pageBg(isDark)
                      : CompetitionUiTokens.titleColor(isDark),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _selectStatus(String status) {
    if (_adminStatusFilter == status) return;
    setState(() {
      _adminStatusFilter = status;
      _selectionMode = false;
      _selectedEventIds.clear();
    });
    _load();
  }

  void _selectMaintenance(String? value) {
    setState(() {
      _maintenanceFilter = value;
      if (value == 'ai_draft') _adminStatusFilter = 'draft';
    });
    _load();
  }

  Future<void> _singleAction(
    int eventId,
    String actionName,
    Future<dynamic> Function(int id) actionFn,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('确认$actionName'),
        content: Text('确认要将该比赛$actionName吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await actionFn(eventId);
      if (!mounted) return;
      AppFeedback.showSnackBar(context, '$actionName成功');
      _load();
    } catch (_) {
      if (!mounted) return;
      AppFeedback.showSnackBar(context, '$actionName失败', isError: true);
    }
  }

  Future<void> _batchAction(
    String actionName,
    Future<dynamic> Function(int id) actionFn,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('确认批量$actionName'),
        content: Text('即将对选中的 ${_selectedEventIds.length} 项比赛执行$actionName。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    var successCount = 0;
    var failCount = 0;
    for (final id in _selectedEventIds) {
      try {
        await actionFn(id);
        successCount++;
      } catch (_) {
        failCount++;
      }
    }
    if (!mounted) return;
    setState(() {
      _selectionMode = false;
      _selectedEventIds.clear();
    });
    AppFeedback.showSnackBar(
      context,
      '$actionName完成：成功 $successCount，失败 $failCount',
    );
    _load();
  }

  Future<void> _openAdminImport() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const CompetitionAdminImportScreen()),
    );
    if (result == true) {
      setState(() {
        _adminStatusFilter = 'draft';
        _maintenanceFilter = 'ai_draft';
        _selectionMode = false;
        _selectedEventIds.clear();
      });
      _load();
    }
  }

  Future<void> _openAdminManualCreate() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => const CompetitionOfficialEventEditorScreen(),
      ),
    );
    if (result == true) _load();
  }

  Future<void> _openAdminDetail(CompetitionEvent event) async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CompetitionOfficialEventEditorScreen(
          initialData: event.toJson(),
        ),
      ),
    );
    if (result == true) _load();
  }

  void _openMaintenanceFilters() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        return Container(
          decoration: BoxDecoration(
            color: CompetitionUiTokens.pageBg(isDark),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          padding: const EdgeInsets.all(24),
          child: SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '维护筛选',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                        color: CompetitionUiTokens.titleColor(isDark),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                _maintenanceOption('全部', null, isDark),
                _maintenanceOption('AI导入草稿', 'ai_draft', isDark),
                _maintenanceOption('缺时间', 'time_pending', isDark),
                _maintenanceOption('可能过期', 'stale', isDark),
                _maintenanceOption('临近截止', 'ending_soon', isDark),
                _maintenanceOption('已结束', 'expired', isDark),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _maintenanceOption(String label, String? value, bool isDark) {
    final selected = _maintenanceFilter == value;
    return ListTile(
      title: Text(
        label,
        style: TextStyle(
          fontWeight: selected ? FontWeight.bold : FontWeight.normal,
          color: selected
              ? CompetitionUiTokens.accent(isDark)
              : CompetitionUiTokens.titleColor(isDark),
        ),
      ),
      trailing: selected
          ? Icon(Icons.check, color: CompetitionUiTokens.accent(isDark))
          : null,
      onTap: () {
        Navigator.pop(context);
        _selectMaintenance(value);
      },
    );
  }

  Future<void> _openAdminFilters() async {
    final result = await showModalBottomSheet<_AdminFilterResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _AdminFilterSheet(
        categories: _categories,
        categorySlug: _categorySlug,
        recommendations: _recommendations,
      ),
    );
    if (result == null) return;
    setState(() {
      _categorySlug = result.categorySlug;
      _recommendations
        ..clear()
        ..addAll(result.recommendations);
    });
    _load();
  }
}

class _AdminFilterResult {
  final String? categorySlug;
  final Set<String> recommendations;

  const _AdminFilterResult({
    required this.categorySlug,
    required this.recommendations,
  });
}

class _AdminFilterSheet extends StatefulWidget {
  final List<CompetitionCategory> categories;
  final String? categorySlug;
  final Set<String> recommendations;

  const _AdminFilterSheet({
    required this.categories,
    required this.categorySlug,
    required this.recommendations,
  });

  @override
  State<_AdminFilterSheet> createState() => _AdminFilterSheetState();
}

class _AdminFilterSheetState extends State<_AdminFilterSheet> {
  String? _categorySlug;
  late Set<String> _recommendations;

  @override
  void initState() {
    super.initState();
    _categorySlug = widget.categorySlug;
    _recommendations = {...widget.recommendations};
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.68,
      minChildSize: 0.42,
      maxChildSize: 0.9,
      builder: (context, scrollController) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        return Container(
          decoration: BoxDecoration(
            color: CompetitionUiTokens.pageBg(isDark),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          ),
          child: Column(
            children: [
              const SizedBox(height: 10),
              Container(
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: CompetitionUiTokens.borderColor(isDark),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 16, 12, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '筛选维护列表',
                        style: TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.w900,
                          color: CompetitionUiTokens.titleColor(isDark),
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () => setState(() {
                        _categorySlug = null;
                        _recommendations.clear();
                      }),
                      child: const Text('重置'),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  controller: scrollController,
                  padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
                  children: [
                    _section('比赛领域', isDark),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _choiceChip(
                          '全部',
                          _categorySlug == null,
                          () => setState(() => _categorySlug = null),
                          isDark,
                        ),
                        ...widget.categories.map(
                          (category) => _choiceChip(
                            category.name,
                            _categorySlug == category.slug,
                            () => setState(
                              () => _categorySlug = category.slug,
                            ),
                            isDark,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    _section('推荐等级', isDark),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: {
                        'S': 'S强烈推荐',
                        'A': 'A推荐',
                        'B+': 'B+较推荐',
                        'B': 'B可参加',
                        'B-': 'B-补充项',
                        'C': 'C兴趣',
                      }.entries.map((entry) {
                        return _choiceChip(
                          entry.value,
                          _recommendations.contains(entry.key),
                          () => setState(() {
                            _recommendations.contains(entry.key)
                                ? _recommendations.remove(entry.key)
                                : _recommendations.add(entry.key);
                          }),
                          isDark,
                        );
                      }).toList(),
                    ),
                  ],
                ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(18, 10, 18, 14),
                  child: FilledButton(
                    onPressed: () => Navigator.pop(
                      context,
                      _AdminFilterResult(
                        categorySlug: _categorySlug,
                        recommendations: {..._recommendations},
                      ),
                    ),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                      backgroundColor: CompetitionUiTokens.accent(isDark),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    child: const Text('查看结果'),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _section(String title, bool isDark) {
    return Text(
      title,
      style: TextStyle(
        color: CompetitionUiTokens.titleColor(isDark),
        fontSize: 15,
        fontWeight: FontWeight.w900,
      ),
    );
  }

  Widget _choiceChip(
    String label,
    bool selected,
    VoidCallback onTap,
    bool isDark,
  ) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
      visualDensity: VisualDensity.compact,
      labelStyle: TextStyle(
        color: selected
            ? CompetitionUiTokens.accent(isDark)
            : CompetitionUiTokens.subColor(isDark),
        fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
      ),
      selectedColor: CompetitionUiTokens.accentSoft(isDark),
      backgroundColor: CompetitionUiTokens.cardBg(isDark),
      side: BorderSide(
        color: selected
            ? CompetitionUiTokens.accent(isDark).withValues(alpha: 0.32)
            : CompetitionUiTokens.borderColor(isDark),
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
    );
  }
}

String _maintenanceLabel(String? value) {
  switch (value) {
    case 'ai_draft':
      return 'AI导入草稿';
    case 'time_pending':
      return '缺时间';
    case 'stale':
      return '可能过期';
    case 'ending_soon':
      return '临近截止';
    case 'expired':
      return '已结束';
    default:
      return '全部';
  }
}
