import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/competition.dart';
import '../../providers/auth_provider.dart';
import '../../utils/app_feedback.dart';
import '../../widgets/competition/competition_center_header.dart';
import '../../widgets/competition/competition_empty_state.dart';
import '../../widgets/competition/competition_event_card.dart';
import '../../widgets/competition/competition_status_helper.dart';
import '../../widgets/competition/competition_ui_tokens.dart';
import '../../widgets/competition/my_competition_plan_card.dart';
import 'competition_calendar_item_detail_screen.dart';

import 'competition_admin_import_screen.dart';
import 'competition_official_event_editor_screen.dart';
const _competitionBg = Color(0xFFFAF8FF);
const _competitionPrimary = Color(0xFF7367C6);
const _competitionPrimaryDark = Color(0xFF4F46A5);
const _competitionLight = Color(0xFFECE9FF);
const _competitionBorder = Color(0xFFE8E4F0);
const _competitionMuted = Color(0xFF8B8794);
const _competitionOrange = Color(0xFFF59E0B);
const _competitionDanger = Color(0xFFEF4444);
const _competitionCategorySlugHint =
    'innovation_startup、computer_ai、electronic_info、smart_manufacturing_vehicle、art_design、business_economics、math_science、materials_chem_env、language_humanities、defense_security_other';


class CompetitionCenterScreen extends StatefulWidget {
  const CompetitionCenterScreen({super.key});

  @override
  State<CompetitionCenterScreen> createState() =>
      _CompetitionCenterScreenState();
}

class _CompetitionCenterScreenState extends State<CompetitionCenterScreen> {
  final _searchController = TextEditingController();
  late Dio _dio;
  List<CompetitionCategory> _categories = [];
  List<CompetitionEvent> _events = [];
  bool _loading = true;
  String? _categorySlug;
  final Set<String> _recommendations = {};
  final Set<String> _recognitions = {};
  final Set<String> _sources = {};
  int? _calendarCount;
  
  String _adminStatusFilter = 'all'; // all, draft, active
  int _adminTotalCount = 0;
  int _adminDraftCount = 0;
  int _adminActiveCount = 0;

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
    final user = context.read<AuthProvider>().user;
    final isAdmin = user?.isAdmin == true || user?.isSuperAdmin == true;

    try {
      final futures = <Future>[
        _dio.get('/competitions/categories'),
      ];

      if (isAdmin) {
        // Fetch all admin events for stats
        futures.add(_dio.get('/admin/competitions/events', queryParameters: {'page_size': 1000}));
        // Fetch specific list based on filter
        futures.add(_dio.get('/admin/competitions/events', queryParameters: _queryParams(isAdmin: true)));
      } else {
        // Normal user fetch
        futures.add(_dio.get('/competitions/events', queryParameters: _queryParams(isAdmin: false)));
      }

      final results = await Future.wait(futures);

      int? calendarCount = _calendarCount;
      if (user != null) {
        try {
          final calendarResp = await _dio.get('/user/competition-calendar');
          calendarCount = ((calendarResp.data['items'] as List?) ?? []).length;
        } catch (_) {
          calendarCount = null;
        }
      }
      
      if (!mounted) return;
      
      setState(() {
        _categories = ((results[0].data as List?) ?? [])
            .map((e) => CompetitionCategory.fromJson(e))
            .toList();

        if (isAdmin) {
          final statsData = ((results[1].data['items'] as List?) ?? [])
              .map((e) => CompetitionEvent.fromJson(e))
              .toList();
          _adminTotalCount = statsData.length;
          _adminDraftCount = statsData.where((e) => e.status == 'draft').length;
          _adminActiveCount = statsData.where((e) => e.status == 'active').length;

          final listData = results[2].data as Map<String, dynamic>;
          _events = ((listData['items'] as List?) ?? [])
              .map((e) => CompetitionEvent.fromJson(e))
              .toList();
        } else {
          final listData = results[1].data as Map<String, dynamic>;
          _events = ((listData['items'] as List?) ?? [])
              .map((e) => CompetitionEvent.fromJson(e))
              .toList();
        }

        _calendarCount = calendarCount;
        _loading = false;
      });
    } on DioException catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      AppFeedback.showSnackBar(
        context,
        AppFeedback.dioErrorMessage(e, fallback: '加载竞赛中心失败'),
        isError: true,
      );
    }
  }

  Map<String, dynamic> _queryParams({required bool isAdmin}) {
    final params = <String, dynamic>{
      'page_size': 50,
      if (_searchController.text.trim().isNotEmpty)
        'keyword': _searchController.text.trim(),
      if (_categorySlug != null) 'category_slug': _categorySlug,
      if (_recommendations.isNotEmpty)
        'recommendation_level': _recommendations.join(','),
      if (_recognitions.isNotEmpty)
        'school_recognition_status': _recognitions.join(','),
      if (_sources.isNotEmpty) 'source_channel': _sources.join(','),
    };
    
    if (isAdmin && _adminStatusFilter != 'all') {
      params['status'] = _adminStatusFilter;
    }
    return params;
  }

  String get _filterSummary {
    final parts = <String>[];
    if (_categorySlug != null) {
      final category = _categories
          .where((item) => item.slug == _categorySlug)
          .cast<CompetitionCategory?>()
          .firstOrNull;
      if (category != null) parts.add(category.name);
    }
    parts.addAll(_recommendations.map((e) => '$e推荐'));
    parts.addAll(_recognitions.map(competitionRecognitionLabel));
    parts.addAll(_sources.map(_sourceLabel));
    if (parts.isEmpty) return '全部比赛';
    if (parts.length <= 3) return parts.join(' · ');
    return '已选 ${parts.length} 项';
  }

  @override
  Widget build(BuildContext context) {
    final user = context.watch<AuthProvider>().user;
    final isAdmin = user?.isAdmin == true || user?.isSuperAdmin == true;
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
          '竞赛中心',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
        actions: [
          if (isAdmin)
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
            CompetitionCenterHeader(
              myPlanCount: _calendarCount ?? 0,
              pendingTimeCount: _events.where((event) => event.registrationEnd == null).length,
              adminTotalCount: _adminTotalCount,
              adminDraftCount: _adminDraftCount,
              adminActiveCount: _adminActiveCount,
              onPrimaryTap: _openAdminImport,
              onSecondaryTap: _openAdminManualCreate,
              searchController: _searchController,
              onSearchSubmitted: (_) => _load(),
              onClearSearch: () {
                _searchController.clear();
                setState(() {});
                _load();
              },
              onCategoryFilterTap: _openFilters,
              onStatusFilterTap: () => AppFeedback.showSnackBar(context, '当前按时间安排排序'),
              onMyPlanTap: _openCalendar,
              filterSummary: _filterSummary,
              isAdmin: isAdmin,
            ),
            
            // 官方比赛库标题区
            Padding(
              padding: const EdgeInsets.fromLTRB(CompetitionUiTokens.pagePadding, 8, CompetitionUiTokens.pagePadding, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '官方比赛库',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w900,
                            color: CompetitionUiTokens.titleColor(isDark),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          isAdmin
                              ? '管理公开展示、草稿和已发布比赛'
                              : '由管理员维护，加入后会复制到我的计划',
                          style: TextStyle(
                            fontSize: 13,
                            color: CompetitionUiTokens.subColor(isDark),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (isAdmin) ...[
                    OutlinedButton(
                      onPressed: _openAdminManualCreate,
                      style: OutlinedButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        foregroundColor: CompetitionUiTokens.titleColor(isDark),
                        side: BorderSide(color: CompetitionUiTokens.borderColor(isDark)),
                      ),
                      child: const Text('新建'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _openAdminImport,
                      style: FilledButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        backgroundColor: CompetitionUiTokens.accent(isDark),
                        foregroundColor: Colors.white,
                      ),
                      child: const Text('AI导入'),
                    ),
                  ],
                ],
              ),
            ),

            // 管理员 Chips
            if (isAdmin)
              Padding(
                padding: const EdgeInsets.fromLTRB(CompetitionUiTokens.pagePadding, 0, CompetitionUiTokens.pagePadding, 16),
                child: Row(
                  children: [
                    _buildAdminChip('全部', 'all', isDark),
                    const SizedBox(width: 8),
                    _buildAdminChip('草稿', 'draft', isDark),
                    const SizedBox(width: 8),
                    _buildAdminChip('已发布', 'active', isDark),
                  ],
                ),
              ),

            // 内容区
            if (_loading)
              const Padding(
                padding: EdgeInsets.only(top: 40),
                child: Center(
                  child: CircularProgressIndicator(
                    color: _competitionPrimary,
                  ),
                ),
              )
            else if (_events.isEmpty)
              CompetitionEmptyState(
                title: isAdmin
                    ? '列表还没有内容'
                    : '暂时没有官方推荐比赛',
                message: isAdmin
                    ? '没有找到符合条件的比赛。'
                    : '暂时没有官方推荐比赛。你可以先导入同学整理的计划，或手动添加想关注的比赛。',
                primaryText: isAdmin ? 'AI导入' : '导入计划',
                onPrimaryTap: isAdmin ? _openAdminImport : _openShareImport,
                secondaryText: isAdmin ? '新建比赛' : '刷新',
                onSecondaryTap: isAdmin ? _openAdminManualCreate : _load,
              )
            else
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: CompetitionUiTokens.pagePadding),
                child: Column(
                  children: _events.map((e) => _buildEventCard(e)).toList(),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildAdminChip(String label, String value, bool isDark) {
    final selected = _adminStatusFilter == value;
    return Material(
      color: selected ? CompetitionUiTokens.titleColor(isDark) : Colors.transparent,
      shape: StadiumBorder(
        side: BorderSide(
          color: selected ? Colors.transparent : CompetitionUiTokens.borderColor(isDark),
        ),
      ),
      child: InkWell(
        onTap: () {
          if (_adminStatusFilter == value) return;
          setState(() {
            _adminStatusFilter = value;
          });
          _load();
        },
        customBorder: const StadiumBorder(),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
              color: selected ? CompetitionUiTokens.pageBg(isDark) : CompetitionUiTokens.titleColor(isDark),
            ),
          ),
        ),
      ),
    );
  }

  // Removed hero card, import button, stat items, search field, filter bar

  Widget _buildEventCard(CompetitionEvent event) {
    return CompetitionEventCard(
      event: event,
      onTap: () => _openDetail(event),
      onAddPlan: () => _copyToCalendar(event.id),
    );
  }



  Future<void> _copyToCalendar(int eventId) async {
    try {
      await _dio
          .post('/user/competition-calendar/items/copy-from-official/$eventId');
      if (!mounted) return;
      AppFeedback.showSnackBar(context, '已加入我的竞赛计划');
    } on DioException catch (e) {
      if (!mounted) return;
      AppFeedback.showSnackBar(
        context,
        AppFeedback.dioErrorMessage(e, fallback: '加入失败，请先登录'),
        isError: true,
      );
    }
  }

  void _openDetail(CompetitionEvent event) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CompetitionDetailScreen(eventId: event.id),
      ),
    );
  }

  Future<void> _openFilters() async {
    final result = await showModalBottomSheet<_CompetitionFilterResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _CompetitionFilterSheet(
        categories: _categories,
        categorySlug: _categorySlug,
        recommendations: _recommendations,
        recognitions: _recognitions,
        sources: _sources,
      ),
    );
    if (result == null) return;
    setState(() {
      _categorySlug = result.categorySlug;
      _recommendations
        ..clear()
        ..addAll(result.recommendations);
      _recognitions
        ..clear()
        ..addAll(result.recognitions);
      _sources
        ..clear()
        ..addAll(result.sources);
    });
    await _load();
  }

  void _openCalendar() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const CompetitionCalendarScreen()),
    );
  }

  void _openShareImport() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const CompetitionShareImportScreen()),
    );
  }

  Future<void> _openAdminImport() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const CompetitionAdminImportScreen()),
    );
    if (result == true) {
      _load();
    }
  }

  Future<void> _openAdminManualCreate() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const CompetitionOfficialEventEditorScreen()),
    );
    if (result == true) {
      _load();
    }
  }
}





class CompetitionDetailScreen extends StatefulWidget {
  final int eventId;
  const CompetitionDetailScreen({super.key, required this.eventId});

  @override
  State<CompetitionDetailScreen> createState() =>
      _CompetitionDetailScreenState();
}

class _CompetitionDetailScreenState extends State<CompetitionDetailScreen> {
  CompetitionEvent? _event;
  Map<String, dynamic> _eventRaw = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final dio = context.read<AuthProvider>().dio;
    final resp = await dio.get('/competitions/events/${widget.eventId}');
    if (!mounted) return;
    setState(() {
      _eventRaw = Map<String, dynamic>.from(resp.data as Map);
      _event = CompetitionEvent.fromJson(_eventRaw);
      _loading = false;
    });
  }

  Future<void> _addToPlan(CompetitionEvent event) async {
    try {
      await context.read<AuthProvider>().dio.post(
          '/user/competition-calendar/items/copy-from-official/${event.id}');
      if (!mounted) return;
      AppFeedback.showSnackBar(context, '已加入我的计划');
    } on DioException catch (e) {
      if (!mounted) return;
      AppFeedback.showSnackBar(
        context,
        AppFeedback.dioErrorMessage(e, fallback: '加入失败，请先登录'),
        isError: true,
      );
    }
  }

  String _rawValue(String key) => '${_eventRaw[key] ?? ''}'.trim();

  @override
  Widget build(BuildContext context) {
    final event = _event;
    return Scaffold(
      backgroundColor: _competitionBg,
      appBar: AppBar(
        backgroundColor: _competitionBg,
        surfaceTintColor: Colors.transparent,
        title: const Text('比赛详情'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : event == null
              ? const Center(child: Text('比赛不存在'))
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    _detailCard(
                      children: [
                        Text(
                          event.title,
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w900,
                            color: Color(0xFF242330),
                            height: 1.25,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            _detailChip('${event.recommendationLevel}推荐'),
                            _detailChip(event.primaryCategory?.name ?? '未分类'),
                            _detailChip(_competitionTimeState(event).label),
                          ],
                        ),
                        if (event.recommendationReason.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          Text(
                            event.recommendationReason,
                            style: const TextStyle(
                              color: _competitionMuted,
                              height: 1.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ],
                    ),
                    _detailCard(
                      title: '时间安排',
                      children: [
                        _detailInfo(
                          _competitionTimeLine(event)?.label ?? '报名安排',
                          _competitionTimeLine(event)?.value ?? '时间待通知',
                        ),
                        _detailInfo('比赛时间', event.eventTimeText),
                        _detailInfo('时间状态', _competitionTimeState(event).label),
                        _detailInfo('时间精度', event.timePrecisionLabel),
                        _detailInfo('时间说明', event.timeNote),
                      ],
                    ),
                    _detailCard(
                      title: '参赛价值',
                      children: [
                        _detailInfo(
                          '学校认定',
                          competitionRecognitionLabel(event.schoolRecognitionStatus),
                        ),
                        _detailInfo('学校等级', event.schoolRecognitionGrade),
                        _detailInfo('推荐等级', event.recommendationLevel),
                        _detailInfo('推荐理由', event.recommendationReason),
                        _detailInfo('适合对象', _rawValue('target_audience')),
                        _detailInfo('参赛形式', _rawValue('participation_type')),
                      ],
                    ),
                    _detailCard(
                      title: '基本信息',
                      children: [
                        _detailInfo('主办方', event.organizer),
                        _detailInfo('比赛级别', event.competitionLevel),
                        _detailInfo(
                            '地点', event.isOnline ? '线上' : event.location),
                        _detailInfo('来源', _sourceLabel(event.sourceChannel)),
                      ],
                    ),
                    _detailCard(
                      title: '比赛说明',
                      children: [
                        Text(
                          (event.description.isNotEmpty
                                  ? event.description
                                  : event.summary)
                              .trim(),
                          style: const TextStyle(height: 1.6),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: () => _addToPlan(event),
                      icon: const Icon(Icons.add),
                      label: const Text('加入我的计划'),
                    ),
                    if (event.officialUrl.isNotEmpty)
                      OutlinedButton.icon(
                        onPressed: () =>
                            launchUrl(Uri.parse(event.officialUrl)),
                        icon: const Icon(Icons.open_in_new),
                        label: const Text('打开官网'),
                      ),
                    if (event.noticeUrl.isNotEmpty)
                      OutlinedButton.icon(
                        onPressed: () => launchUrl(Uri.parse(event.noticeUrl)),
                        icon: const Icon(Icons.article_outlined),
                        label: const Text('查看通知'),
                      ),
                  ],
                ),
    );
  }
}

Widget _detailCard({String? title, required List<Widget> children}) {
  return Container(
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: _competitionBorder),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title != null) ...[
          Text(
            title,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w900,
              color: Color(0xFF242330),
            ),
          ),
          const SizedBox(height: 10),
        ],
        ...children,
      ],
    ),
  );
}

Widget _detailChip(String label) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
    decoration: BoxDecoration(
      color: _competitionLight,
      borderRadius: BorderRadius.circular(999),
    ),
    child: Text(
      label,
      style: const TextStyle(
        color: _competitionPrimaryDark,
        fontSize: 12,
        fontWeight: FontWeight.w800,
      ),
    ),
  );
}

Widget _detailInfo(String label, String value) {
  if (value.trim().isEmpty) return const SizedBox.shrink();
  return Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 74,
          child: Text(
            label,
            style: const TextStyle(
              color: _competitionMuted,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(
              color: Color(0xFF242330),
              fontSize: 13,
              height: 1.4,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    ),
  );
}

class _CompetitionFilterResult {
  final String? categorySlug;
  final Set<String> recommendations;
  final Set<String> recognitions;
  final Set<String> sources;

  const _CompetitionFilterResult({
    required this.categorySlug,
    required this.recommendations,
    required this.recognitions,
    required this.sources,
  });
}

class _CompetitionFilterSheet extends StatefulWidget {
  final List<CompetitionCategory> categories;
  final String? categorySlug;
  final Set<String> recommendations;
  final Set<String> recognitions;
  final Set<String> sources;

  const _CompetitionFilterSheet({
    required this.categories,
    required this.categorySlug,
    required this.recommendations,
    required this.recognitions,
    required this.sources,
  });

  @override
  State<_CompetitionFilterSheet> createState() =>
      _CompetitionFilterSheetState();
}

class _CompetitionFilterSheetState extends State<_CompetitionFilterSheet> {
  String? _categorySlug;
  late Set<String> _recommendations;
  late Set<String> _recognitions;
  late Set<String> _sources;

  @override
  void initState() {
    super.initState();
    _categorySlug = widget.categorySlug;
    _recommendations = {...widget.recommendations};
    _recognitions = {...widget.recognitions};
    _sources = {...widget.sources};
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.78,
      minChildSize: 0.45,
      maxChildSize: 0.92,
      builder: (context, scrollController) {
        return Container(
          decoration: const BoxDecoration(
            color: _competitionBg,
            borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
          ),
          child: Column(
            children: [
              const SizedBox(height: 10),
              Container(
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: _competitionBorder,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 16, 12, 8),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '筛选比赛',
                        style: TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () => setState(() {
                        _categorySlug = null;
                        _recommendations.clear();
                        _recognitions.clear();
                        _sources.clear();
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
                    _sheetSection('比赛领域'),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _choiceChip('全部', _categorySlug == null,
                            () => setState(() => _categorySlug = null)),
                        ...widget.categories.map(
                          (c) => _choiceChip(
                            c.name,
                            _categorySlug == c.slug,
                            () => setState(() => _categorySlug = c.slug),
                          ),
                        ),
                      ],
                    ),
                    _sheetMulti(
                      '推荐程度',
                      {'S': 'S强烈推荐', 'A': 'A推荐', 'B': 'B可参加', 'C': 'C兴趣'},
                      _recommendations,
                    ),
                    _sheetMulti(
                      '学校认定',
                      {
                        'recognized': '已认定',
                        'not_recognized': '未认定',
                        'pending': '待确认',
                        'unknown': '未知',
                      },
                      _recognitions,
                    ),
                    _sheetMulti(
                      '来源类型',
                      {
                        'school_catalog': '学校目录',
                        'enterprise': '企业赛事',
                        'college_notice': '学院通知',
                        'industry_association': '行业协会',
                        'platform': '平台赛事',
                        'admin_manual': '管理员精选',
                        'ai_import': 'AI导入',
                      },
                      _sources,
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
                      _CompetitionFilterResult(
                        categorySlug: _categorySlug,
                        recommendations: {..._recommendations},
                        recognitions: {..._recognitions},
                        sources: {..._sources},
                      ),
                    ),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                      backgroundColor: _competitionPrimary,
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

  Widget _sheetSection(String title) {
    return Text(
      title,
      style: const TextStyle(
        color: Color(0xFF252433),
        fontSize: 15,
        fontWeight: FontWeight.w900,
      ),
    );
  }

  Widget _sheetMulti(
      String title, Map<String, String> options, Set<String> set) {
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sheetSection(title),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: options.entries
                .map((entry) => _choiceChip(
                      entry.value,
                      set.contains(entry.key),
                      () => setState(() {
                        set.contains(entry.key)
                            ? set.remove(entry.key)
                            : set.add(entry.key);
                      }),
                    ))
                .toList(),
          ),
        ],
      ),
    );
  }

  Widget _choiceChip(String label, bool selected, VoidCallback onTap) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
      visualDensity: VisualDensity.compact,
      labelStyle: TextStyle(
        color: selected ? _competitionPrimaryDark : _competitionMuted,
        fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
      ),
      selectedColor: _competitionLight,
      backgroundColor: Colors.white,
      side: BorderSide(
        color: selected
            ? _competitionPrimary.withValues(alpha: 0.32)
            : _competitionBorder,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
    );
  }
}

class CompetitionCalendarScreen extends StatefulWidget {
  const CompetitionCalendarScreen({super.key});

  @override
  State<CompetitionCalendarScreen> createState() =>
      _CompetitionCalendarScreenState();
}

class _CompetitionCalendarScreenState extends State<CompetitionCalendarScreen> {
  List<dynamic> _items = [];
  List<CompetitionCategory> _categories = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    try {
      final dio = context.read<AuthProvider>().dio;
      final results = await Future.wait([
        dio.get('/user/competition-calendar'),
        dio.get('/competitions/categories'),
      ]);
      if (!mounted) return;
      setState(() {
        _items = (results[0].data['items'] as List?) ?? [];
        _categories = ((results[1].data as List?) ?? [])
            .map((e) => CompetitionCategory.fromJson(e))
            .toList();
        _loading = false;
      });
    } on DioException catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      AppFeedback.showSnackBar(
        context,
        AppFeedback.dioErrorMessage(e, fallback: '加载我的竞赛计划失败'),
        isError: true,
      );
    }
  }

  Future<void> _share() async {
    try {
      if (!mounted) return;
      final resp = await context
          .read<AuthProvider>()
          .dio
          .post('/user/competition-calendar/share');
      if (!mounted) return;
      final code = '${resp.data['share_code'] ?? ''}';
      await Clipboard.setData(ClipboardData(text: code));
      if (!mounted) return;
      AppFeedback.showSnackBar(context, '分享码已复制：$code');
    } on DioException catch (e) {
      if (!mounted) return;
      AppFeedback.showSnackBar(
        context,
        AppFeedback.dioErrorMessage(e, fallback: '生成分享码失败'),
        isError: true,
      );
    }
  }

  Future<void> _openEditor({Map<String, dynamic>? item}) async {
    if (_categories.isEmpty) {
      AppFeedback.showSnackBar(context, '分类加载失败，暂时无法编辑比赛', isError: true);
      return;
    }
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => CompetitionCalendarItemEditorScreen(
          categories: _categories,
          item: item,
        ),
      ),
    );
    if (changed == true) {
      await _load();
    }
  }

  Future<void> _openCalendarItemDetail(Map<String, dynamic> item) async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => CompetitionCalendarItemDetailScreen(
          item: item,
          categories: _categories,
        ),
      ),
    );

    if (changed == true) {
      await _load();
    }
  }

  Future<void> _deleteItem(Map<String, dynamic> item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除比赛'),
        content: Text('确定从我的计划删除「${item['title'] ?? '未命名比赛'}」吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final dio = context.read<AuthProvider>().dio;
    try {
      await dio.delete('/user/competition-calendar/items/${item['id']}');
      if (!mounted) return;
      AppFeedback.showSnackBar(context, '已删除比赛');
      await _load();
    } on DioException catch (e) {
      if (!mounted) return;
      AppFeedback.showSnackBar(
        context,
        AppFeedback.dioErrorMessage(e, fallback: '删除失败'),
        isError: true,
      );
    }
  }

  Future<void> _archiveItem(Map<String, dynamic> item) async {
    final data = _calendarItemUpdatePayload(item)..['plan_status'] = 'archived';
    try {
      await context
          .read<AuthProvider>()
          .dio
          .put('/user/competition-calendar/items/${item['id']}', data: data);
      if (!mounted) return;
      AppFeedback.showSnackBar(context, '已归档比赛');
      await _load();
    } on DioException catch (e) {
      if (!mounted) return;
      AppFeedback.showSnackBar(
        context,
        AppFeedback.dioErrorMessage(e, fallback: '归档失败'),
        isError: true,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final pageBg = CompetitionUiTokens.pageBg(isDark);
    final titleColor = CompetitionUiTokens.titleColor(isDark);
    
    final items = _calendarItems;
    final grouped = _groupCalendarItems(items);
    return Scaffold(
      backgroundColor: pageBg,
      appBar: AppBar(
        backgroundColor: pageBg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        foregroundColor: titleColor,
        centerTitle: true,
        title: Text(
          '我的竞赛计划',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w700,
            color: titleColor,
          ),
        ),
        actions: [
          IconButton(
            tooltip: '新增比赛',
            onPressed: () => _openEditor(),
            icon: const Icon(Icons.add_rounded),
          ),
          IconButton(
            tooltip: '导入计划',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const CompetitionShareImportScreen(),
              ),
            ).then((_) => _load()),
            icon: const Icon(Icons.input_rounded),
          ),
          IconButton(
            tooltip: '生成分享码',
            onPressed: _share,
            icon: const Icon(Icons.ios_share),
          ),
        ],
      ),
      body: _loading
          ? Center(child: CircularProgressIndicator(color: CompetitionUiTokens.accent(isDark)))
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                if (items.isEmpty)
                  CompetitionEmptyState(
                    title: '还没有加入竞赛计划',
                    message: '时间不确定也可以先关注比赛，后续看到学校通知后再补充准确时间。',
                    primaryText: '去发现比赛',
                    onPrimaryTap: () => Navigator.maybePop(context),
                    secondaryText: '手动添加',
                    onSecondaryTap: () => _openEditor(),
                  ),
                if (items.isNotEmpty) ...[
                  _buildPlanGroup('现在该做', grouped['now']!),
                  _buildPlanGroup('近期关注', grouped['soon']!),
                  _buildPlanGroup('长期关注', grouped['later']!),
                  _buildPlanGroup('已结束', grouped['done']!),
                ],
              ],
            ),
    );
  }

  List<Map<String, dynamic>> get _calendarItems => _items
      .whereType<Map>()
      .map((item) => Map<String, dynamic>.from(item))
      .toList();



  Widget _buildPlanGroup(String title, List<Map<String, dynamic>> items) {
    if (items.isEmpty) return const SizedBox.shrink();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 8, 2, 6),
            child: Row(
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: CompetitionUiTokens.accent(isDark),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: TextStyle(
                    color: CompetitionUiTokens.titleColor(isDark),
                    fontSize: 15,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '${items.length}',
                  style: TextStyle(
                    color: CompetitionUiTokens.subColor(isDark),
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          ...items.map(_buildPlanCard),
        ],
      ),
    );
  }

  Widget _buildPlanCard(Map<String, dynamic> item) {
    final deadline = _calendarItemTimeText(
      item,
      'registration_end',
      'registration_time_text',
    );
    final source = competitionSourceLabel('${item['source_type'] ?? ''}');
    final planStatus = _calendarPlanStatus(item);
    final timeStatus = _calendarTimeStatus(item);
    
    return MyCompetitionPlanCard(
      item: item,
      planStatusLabel: _planStatusLabel(planStatus),
      timeStatusLabel: _timeStatusLabel(timeStatus),
      sourceLabel: source,
      deadlineText: deadline,
      onTap: () => _openCalendarItemDetail(item),
      onEdit: () => _openEditor(item: item),
      onDelete: () => _deleteItem(item),
      onArchive: () => _archiveItem(item),
    );
  }

  Map<String, List<Map<String, dynamic>>> _groupCalendarItems(
    List<Map<String, dynamic>> items,
  ) {
    final groups = {
      'now': <Map<String, dynamic>>[],
      'soon': <Map<String, dynamic>>[],
      'later': <Map<String, dynamic>>[],
      'done': <Map<String, dynamic>>[],
    };
    for (final item in items) {
      final key = _calendarItemGroup(item);
      groups[key]!.add(item);
    }
    return groups;
  }

  String _calendarItemGroup(Map<String, dynamic> item) {
    final now = DateTime.now();
    final planStatus = _calendarPlanStatus(item);
    final deadline = _parseCalendarDate(item['registration_end']);
    if (planStatus == 'finished' ||
        planStatus == 'archived' ||
        (deadline != null && deadline.isBefore(now))) {
      return 'done';
    }
    final userDeadline = _parseCalendarDate(item['user_deadline']);
    if (_isWithinDays(deadline, now, 30) ||
        _isWithinDays(userDeadline, now, 30) ||
        const {'preparing', 'registered', 'submitted'}.contains(planStatus)) {
      return 'now';
    }
    final sortDate = _parseCalendarDate(item['sort_date']);
    final sortMonth = _calendarInt(item['sort_month']);
    if (_isWithinDays(sortDate, now, 90) || _isNearMonth(sortMonth, now)) {
      return 'soon';
    }
    return 'later';
  }

  Map<String, dynamic> _calendarItemUpdatePayload(Map<String, dynamic> item) {
    return {
      'title': '${item['title'] ?? ''}',
      'summary': '${item['summary'] ?? ''}',
      'description': '${item['description'] ?? ''}',
      'primary_category_id': _calendarInt(item['category_id']),
      'competition_level':
          '${item['competition_level'] ?? item['level'] ?? ''}',
      'school_recognition_status':
          '${item['school_recognition_status'] ?? 'pending'}',
      'recommendation_level': '${item['recommendation_level'] ?? 'A'}',
      'organizer': '${item['organizer'] ?? ''}',
      'registration_end': _calendarDateOnly(item['registration_end']),
      'registration_time_text': '${item['registration_time_text'] ?? ''}',
      'event_start': _calendarDateOnly(item['event_start']),
      'event_time_text': '${item['event_time_text'] ?? ''}',
      'time_precision': '${item['time_precision'] ?? 'unknown'}',
      'time_status': _calendarTimeStatus(item),
      'time_note': '${item['time_note'] ?? ''}',
      'sort_month': _calendarInt(item['sort_month']),
      'user_deadline': _calendarDateOnly(item['user_deadline']),
      'location': '${item['location'] ?? ''}',
      'is_online': item['is_online'] == true,
      'official_url': '${item['official_url'] ?? ''}',
      'notice_url': '${item['notice_url'] ?? ''}',
      'source_channel': 'user_submitted',
      'status': 'draft',
      'tags': <String>[],
      'attachment_urls': <String>[],
    };
  }



  String _calendarPlanStatus(Map<String, dynamic> item) {
    final value = '${item['plan_status'] ?? ''}'.trim();
    return value.isEmpty ? 'watching' : value;
  }

  String _calendarTimeStatus(Map<String, dynamic> item) {
    final value = '${item['time_status'] ?? ''}'.trim();
    if (value.isNotEmpty) return value;
    if (_parseCalendarDate(item['registration_end']) != null) {
      return 'confirmed';
    }
    final text =
        '${item['registration_time_text'] ?? ''} ${item['event_time_text'] ?? ''}';
    if (_containsAny(text, const ['预计', '暂定', '计划', '大概', '约'])) {
      return 'estimated';
    }
    if (_containsAny(text, const ['往年', '历年', '通常', '一般', '参考'])) {
      return 'historical';
    }
    return 'pending';
  }

  int _calendarInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse('$value') ?? 0;
  }

  DateTime? _parseCalendarDate(dynamic value) {
    final raw = '${value ?? ''}'.trim();
    if (raw.isEmpty || raw == 'null') return null;
    return DateTime.tryParse(raw);
  }

  String _calendarDateOnly(dynamic value) {
    final parsed = _parseCalendarDate(value);
    if (parsed == null) return '';
    return '${parsed.year}-${parsed.month.toString().padLeft(2, '0')}-${parsed.day.toString().padLeft(2, '0')}';
  }

  bool _isWithinDays(DateTime? date, DateTime now, int days) {
    if (date == null || date.isBefore(now)) return false;
    return date.difference(now).inDays <= days;
  }

  bool _isNearMonth(int month, DateTime now) {
    if (month < 1 || month > 12) return false;
    for (var offset = 0; offset < 3; offset++) {
      final candidate = DateTime(now.year, now.month + offset, 1);
      if (candidate.month == month) return true;
    }
    return false;
  }

  String _planStatusLabel(String value) {
    switch (value) {
      case 'preparing':
        return '准备中';
      case 'registered':
        return '已报名';
      case 'submitted':
        return '已提交';
      case 'finished':
        return '已结束';
      case 'archived':
        return '已归档';
      default:
        return '关注中';
    }
  }
}

class CompetitionCalendarItemEditorScreen extends StatefulWidget {
  final List<CompetitionCategory> categories;
  final Map<String, dynamic>? item;

  const CompetitionCalendarItemEditorScreen({
    super.key,
    required this.categories,
    this.item,
  });

  @override
  State<CompetitionCalendarItemEditorScreen> createState() =>
      _CompetitionCalendarItemEditorScreenState();
}

class _CompetitionCalendarItemEditorScreenState
    extends State<CompetitionCalendarItemEditorScreen> {
  final _titleController = TextEditingController();
  final _summaryController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _organizerController = TextEditingController();
  final _competitionLevelController = TextEditingController();
  final _registrationEndController = TextEditingController();
  final _registrationTextController = TextEditingController();
  final _eventStartController = TextEditingController();
  final _eventTextController = TextEditingController();
  final _locationController = TextEditingController();
  final _officialUrlController = TextEditingController();
  final _noticeUrlController = TextEditingController();

  int? _categoryId;
  String _recognition = 'pending';
  String _recommendation = 'A';
  bool _isOnline = false;
  bool _saving = false;

  bool get _isEditing => widget.item != null;

  @override
  void initState() {
    super.initState();
    final item = widget.item;
    _categoryId = _intValue(item?['category_id']);
    if (_categoryId == null || _categoryId == 0) {
      _categoryId = widget.categories.first.id;
    }
    _titleController.text = '${item?['title'] ?? ''}';
    _summaryController.text = '${item?['summary'] ?? ''}';
    _descriptionController.text = '${item?['description'] ?? ''}';
    _organizerController.text = '${item?['organizer'] ?? ''}';
    _competitionLevelController.text = '${item?['competition_level'] ?? ''}';
    _registrationEndController.text = _dateOnly(item?['registration_end']);
    _registrationTextController.text =
        '${item?['registration_time_text'] ?? ''}';
    _eventStartController.text = _dateOnly(item?['event_start']);
    _eventTextController.text = '${item?['event_time_text'] ?? ''}';
    _locationController.text = '${item?['location'] ?? ''}';
    _officialUrlController.text = '${item?['official_url'] ?? ''}';
    _noticeUrlController.text = '${item?['notice_url'] ?? ''}';
    _recognition = '${item?['school_recognition_status'] ?? 'pending'}';
    if (_recognition.isEmpty) _recognition = 'pending';
    _recommendation = '${item?['recommendation_level'] ?? 'A'}';
    if (_recommendation.isEmpty) _recommendation = 'A';
    _isOnline = item?['is_online'] == true;
  }

  @override
  void dispose() {
    _titleController.dispose();
    _summaryController.dispose();
    _descriptionController.dispose();
    _organizerController.dispose();
    _competitionLevelController.dispose();
    _registrationEndController.dispose();
    _registrationTextController.dispose();
    _eventStartController.dispose();
    _eventTextController.dispose();
    _locationController.dispose();
    _officialUrlController.dispose();
    _noticeUrlController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final title = _titleController.text.trim();
    if (title.isEmpty) {
      AppFeedback.showSnackBar(context, '请填写比赛名称', isError: true);
      return;
    }
    if (_categoryId == null || _categoryId == 0) {
      AppFeedback.showSnackBar(context, '请选择比赛分类', isError: true);
      return;
    }
    setState(() => _saving = true);
    final data = {
      'title': title,
      'summary': _summaryController.text.trim(),
      'description': _descriptionController.text.trim(),
      'primary_category_id': _categoryId,
      'competition_level': _competitionLevelController.text.trim(),
      'school_recognition_status': _recognition,
      'recommendation_level': _recommendation,
      'organizer': _organizerController.text.trim(),
      'registration_end': _registrationEndController.text.trim(),
      'registration_time_text': _registrationTextController.text.trim(),
      'event_start': _eventStartController.text.trim(),
      'event_time_text': _eventTextController.text.trim(),
      'location': _locationController.text.trim(),
      'is_online': _isOnline,
      'official_url': _officialUrlController.text.trim(),
      'notice_url': _noticeUrlController.text.trim(),
      'source_channel': 'user_submitted',
      'status': 'draft',
      'tags': <String>[],
      'attachment_urls': <String>[],
    };

    try {
      final dio = context.read<AuthProvider>().dio;
      if (_isEditing) {
        await dio.put(
          '/user/competition-calendar/items/${widget.item!['id']}',
          data: data,
        );
      } else {
        await dio.post('/user/competition-calendar/items', data: data);
      }
      if (!mounted) return;
      AppFeedback.showSnackBar(context, _isEditing ? '已更新比赛' : '已新增比赛');
      Navigator.pop(context, true);
    } on DioException catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      AppFeedback.showSnackBar(
        context,
        AppFeedback.dioErrorMessage(e, fallback: _isEditing ? '更新失败' : '新增失败'),
        isError: true,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final pageBg = CompetitionUiTokens.pageBg(isDark);
    final titleColor = CompetitionUiTokens.titleColor(isDark);

    return Scaffold(
      backgroundColor: pageBg,
      appBar: AppBar(
        backgroundColor: pageBg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        foregroundColor: titleColor,
        centerTitle: true,
        title: Text(
          _isEditing ? '编辑比赛' : '新增比赛',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w700,
            color: titleColor,
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          _buildFormGroup('基础信息', [
            _input(_titleController, '比赛名称', required: true, isDark: isDark),
            const SizedBox(height: 12),
            _input(_summaryController, '一句话摘要', isDark: isDark),
            const SizedBox(height: 12),
            _input(_descriptionController, '比赛说明', minLines: 4, maxLines: 8, isDark: isDark),
          ], isDark),

          _buildFormGroup('分类与推荐', [
            DropdownButtonFormField<int>(
              initialValue: _categoryId,
              decoration: _inputDecoration('比赛分类', isDark),
              items: widget.categories
                  .map((c) => DropdownMenuItem(value: c.id, child: Text(c.name)))
                  .toList(),
              onChanged: (value) => setState(() => _categoryId = value),
            ),
            const SizedBox(height: 12),
            _input(_competitionLevelController, '比赛级别', isDark: isDark),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _recommendation,
                    decoration: _inputDecoration('推荐程度', isDark),
                    items: const [
                      DropdownMenuItem(value: 'S', child: Text('S 强烈推荐')),
                      DropdownMenuItem(value: 'A', child: Text('A 推荐')),
                      DropdownMenuItem(value: 'B', child: Text('B 可参加')),
                      DropdownMenuItem(value: 'C', child: Text('C 兴趣')),
                    ],
                    onChanged: (value) => setState(() => _recommendation = value ?? 'A'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _recognition,
                    decoration: _inputDecoration('学校认定', isDark),
                    items: const [
                      DropdownMenuItem(value: 'recognized', child: Text('已认定')),
                      DropdownMenuItem(value: 'not_recognized', child: Text('未认定')),
                      DropdownMenuItem(value: 'pending', child: Text('待确认')),
                      DropdownMenuItem(value: 'unknown', child: Text('未知')),
                    ],
                    onChanged: (value) => setState(() => _recognition = value ?? 'pending'),
                  ),
                ),
              ],
            ),
          ], isDark),

          _buildFormGroup('时间安排', [
            _input(_registrationEndController, '报名截止日期 YYYY-MM-DD', isDark: isDark),
            const SizedBox(height: 12),
            _input(_registrationTextController, '报名时间说明', isDark: isDark),
            const SizedBox(height: 12),
            _input(_eventStartController, '比赛开始日期 YYYY-MM-DD', isDark: isDark),
            const SizedBox(height: 12),
            _input(_eventTextController, '比赛时间说明', isDark: isDark),
            const SizedBox(height: 12),
            SwitchListTile(
              value: _isOnline,
              onChanged: (value) => setState(() => _isOnline = value),
              title: const Text('线上比赛'),
              contentPadding: EdgeInsets.zero,
              activeThumbColor: Colors.white,
              activeTrackColor: CompetitionUiTokens.accent(isDark),
            ),
          ], isDark),

          _buildFormGroup('地点与链接', [
            _input(_locationController, '地点', isDark: isDark),
            const SizedBox(height: 12),
            _input(_officialUrlController, '官网链接', isDark: isDark),
            const SizedBox(height: 12),
            _input(_noticeUrlController, '通知链接', isDark: isDark),
          ], isDark),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: FilledButton(
            onPressed: _saving ? null : _save,
            style: FilledButton.styleFrom(
              backgroundColor: CompetitionUiTokens.accent(isDark),
              minimumSize: const Size.fromHeight(52),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
              ),
            ),
            child: Text(_saving ? '保存中...' : '保存比赛'),
          ),
        ),
      ),
    );
  }

  Widget _buildFormGroup(String title, List<Widget> children, bool isDark) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: CompetitionUiTokens.cardDecoration(isDark),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: CompetitionUiTokens.titleColor(isDark),
            ),
          ),
          const SizedBox(height: 16),
          ...children,
        ],
      ),
    );
  }

  Widget _input(
    TextEditingController controller,
    String label, {
    bool required = false,
    int minLines = 1,
    int maxLines = 1,
    required bool isDark,
  }) {
    return TextField(
      controller: controller,
      minLines: minLines,
      maxLines: maxLines,
      decoration: _inputDecoration(required ? '$label *' : label, isDark),
    );
  }

  InputDecoration _inputDecoration(String label, bool isDark) {
    return InputDecoration(
      labelText: label,
      filled: true,
      fillColor: CompetitionUiTokens.cardBg(isDark),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: CompetitionUiTokens.borderColor(isDark)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: CompetitionUiTokens.borderColor(isDark)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(
          color: CompetitionUiTokens.accent(isDark),
          width: 1.3,
        ),
      ),
    );
  }

  int? _intValue(dynamic value) {
    if (value is num) return value.toInt();
    return int.tryParse('$value');
  }

  String _dateOnly(dynamic value) {
    final raw = '${value ?? ''}'.trim();
    if (raw.isEmpty || raw == 'null') return '';
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return raw;
    return '${parsed.year}-${parsed.month.toString().padLeft(2, '0')}-${parsed.day.toString().padLeft(2, '0')}';
  }
}

enum _ImportMode { shareCode, jsonFile }

class CompetitionShareImportScreen extends StatefulWidget {
  const CompetitionShareImportScreen({super.key});

  @override
  State<CompetitionShareImportScreen> createState() =>
      _CompetitionShareImportScreenState();
}

class _CompetitionShareImportScreenState
    extends State<CompetitionShareImportScreen> {
  _ImportMode _mode = _ImportMode.shareCode;

  final _controller = TextEditingController();
  Map<String, dynamic>? _preview;
  bool _readingJsonFile = false;
  String? _jsonFileName;
  Map<String, dynamic>? _jsonPayload;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _previewShare() async {
    if (!mounted) return;
      final resp = await context.read<AuthProvider>().dio.post(
      '/user/competition-calendar/import-share/preview',
      data: {'share_code': _controller.text.trim()},
    );
    if (!mounted) return;
    setState(() => _preview = Map<String, dynamic>.from(resp.data));
  }

  Future<void> _commitShare(String strategy) async {
    await context.read<AuthProvider>().dio.post(
      '/user/competition-calendar/import-share/commit',
      data: {'share_code': _controller.text.trim(), 'strategy': strategy},
    );
    if (!mounted) return;
    AppFeedback.showSnackBar(context, '导入完成');
    Navigator.pop(context);
  }

  Future<void> _pickJsonFile() async {
    try {
      setState(() => _readingJsonFile = true);

      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
        withData: true,
        withReadStream: true,
      );

      if (result == null || result.files.isEmpty) return;

      final file = result.files.single;

      String? text;
      if (file.bytes != null) {
        text = utf8.decode(file.bytes!).trim();
      } else if (file.readStream != null) {
        text = await file.readStream!.transform(utf8.decoder).join();
        text = text.trim();
      }

      if (text == null || text.isEmpty) {
        if (!mounted) return;
        AppFeedback.showSnackBar(
          context,
          '读取文件失败，请重新选择 JSON 文件',
          isError: true,
        );
        return;
      }

      final decoded = jsonDecode(text);

      if (decoded is! Map<String, dynamic> || decoded['events'] is! List) {
        if (!mounted) return;
        AppFeedback.showSnackBar(
          context,
          'JSON 顶层必须是 {"events": [...]}',
          isError: true,
        );
        return;
      }

      if (!mounted) return;
      final resp = await context.read<AuthProvider>().dio.post(
            '/user/competition-calendar/import-json/preview',
            data: decoded,
          );

      if (!mounted) return;

      setState(() {
        _jsonFileName = file.name;
        _jsonPayload = decoded;
        _preview = Map<String, dynamic>.from(resp.data['preview']);
      });

      AppFeedback.showSnackBar(context, '已读取 ${file.name}');
    } on FormatException {
      AppFeedback.showSnackBar(
        context,
        'JSON 格式不正确，请检查逗号、引号和括号',
        isError: true,
      );
    } on DioException catch (e) {
      if (!mounted) return;
      AppFeedback.showSnackBar(
        context,
        AppFeedback.dioErrorMessage(e, fallback: '读取 JSON 文件或预览失败'),
        isError: true,
      );
    } catch (e) {
      if (!mounted) return;
      AppFeedback.showSnackBar(
        context,
        '读取 JSON 文件或预览失败：$e',
        isError: true,
      );
    } finally {
      if (mounted) {
        setState(() => _readingJsonFile = false);
      }
    }
  }

  Future<void> _commitJson(String strategy) async {
    if (_jsonPayload == null) return;
    try {
      await context.read<AuthProvider>().dio.post(
        '/user/competition-calendar/import-json/commit',
        data: {
          'strategy': strategy,
          'events': _jsonPayload!['events'],
        },
      );
      if (!mounted) return;
      AppFeedback.showSnackBar(context, '导入完成');
      Navigator.pop(context);
    } on DioException catch (e) {
      if (!mounted) return;
      AppFeedback.showSnackBar(
        context,
        AppFeedback.dioErrorMessage(e, fallback: '导入失败'),
        isError: true,
      );
    } catch (e) {
      if (!mounted) return;
      AppFeedback.showSnackBar(
        context,
        '导入失败：$e',
        isError: true,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = (_preview?['items'] as List?) ?? [];
    return Scaffold(
      appBar: AppBar(title: const Text('导入计划')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SegmentedButton<_ImportMode>(
            segments: const [
              ButtonSegment(
                value: _ImportMode.shareCode,
                label: Text('分享码导入'),
              ),
              ButtonSegment(
                value: _ImportMode.jsonFile,
                label: Text('JSON 文件导入'),
              ),
            ],
            selected: {_mode},
            onSelectionChanged: (Set<_ImportMode> newSelection) {
              setState(() {
                _mode = newSelection.first;
                _preview = null;
              });
            },
          ),
          const SizedBox(height: 24),
          if (_mode == _ImportMode.shareCode) ...[
            TextField(
              controller: _controller,
              decoration: const InputDecoration(labelText: '分享码'),
            ),
            const SizedBox(height: 12),
            FilledButton(onPressed: _previewShare, child: const Text('预览')),
          ] else ...[
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFE8E4F0)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _jsonFileName == null ? '未选择文件' : '已选择: $_jsonFileName',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _readingJsonFile ? null : _pickJsonFile,
                    icon: const Icon(Icons.upload_file_rounded, size: 18),
                    label: Text(_readingJsonFile ? '读取中...' : '选择 JSON 文件'),
                  ),
                ],
              ),
            ),
          ],
          if (_preview != null) ...[
            const SizedBox(height: 16),
            Text('预览 ${items.length} 个比赛',
                style: const TextStyle(fontWeight: FontWeight.w800)),
            ...items.map((e) => ListTile(title: Text(e['title'] ?? ''))),
            Row(children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _mode == _ImportMode.shareCode
                      ? _commitShare('merge')
                      : _commitJson('merge'),
                  child: const Text('合并'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  onPressed: () => _mode == _ImportMode.shareCode
                      ? _commitShare('replace')
                      : _commitJson('replace'),
                  child: const Text('覆盖'),
                ),
              ),
            ]),
          ],
        ],
      ),
    );
  }
}


class _CompetitionTimeState {
  final String label;
  final Color color;
  final bool highlight;

  const _CompetitionTimeState({
    required this.label,
    required this.color,
    this.highlight = false,
  });
}

class _CompetitionTimeLine {
  final IconData icon;
  final String label;
  final String value;

  const _CompetitionTimeLine({
    required this.icon,
    required this.label,
    required this.value,
  });
}

_CompetitionTimeState _competitionTimeState(CompetitionEvent event) {
  final deadline = event.registrationEnd;
  if (deadline != null) {
    if (deadline.isBefore(DateTime.now())) {
      return const _CompetitionTimeState(
        label: '已截止',
        color: _competitionDanger,
      );
    }
    return const _CompetitionTimeState(
      label: '已确认',
      color: _competitionPrimary,
      highlight: true,
    );
  }

  if (event.hasTimeStatus) {
    switch (event.timeStatus) {
      case 'confirmed':
        return const _CompetitionTimeState(
          label: '已确认',
          color: _competitionPrimary,
          highlight: true,
        );
      case 'estimated':
        return const _CompetitionTimeState(
          label: '预计时间',
          color: _competitionOrange,
          highlight: true,
        );
      case 'historical':
        return const _CompetitionTimeState(
          label: '往年参考',
          color: _competitionPrimaryDark,
        );
      default:
        return const _CompetitionTimeState(
          label: '待通知',
          color: _competitionMuted,
        );
    }
  }

  final text = '${event.registrationTimeText} ${event.eventTimeText}';
  if (_containsAny(text, const ['预计', '暂定', '计划', '大概', '约'])) {
    return const _CompetitionTimeState(
      label: '预计时间',
      color: _competitionOrange,
      highlight: true,
    );
  }
  if (_containsAny(text, const ['往年', '历年', '通常', '一般', '参考'])) {
    return const _CompetitionTimeState(
      label: '往年参考',
      color: _competitionPrimaryDark,
    );
  }
  return const _CompetitionTimeState(
    label: '待通知',
    color: _competitionMuted,
  );
}

_CompetitionTimeLine? _competitionTimeLine(CompetitionEvent event) {
  final deadline = _deadlineText(event);
  if (event.registrationEnd != null) {
    return _CompetitionTimeLine(
      icon: Icons.alarm_rounded,
      label: '报名截止',
      value: deadline,
    );
  }
  if (event.registrationTimeText.trim().isNotEmpty) {
    return _CompetitionTimeLine(
      icon: Icons.schedule_rounded,
      label: '报名窗口',
      value: event.registrationTimeText.trim(),
    );
  }
  if (event.eventTimeText.trim().isNotEmpty) {
    return _CompetitionTimeLine(
      icon: Icons.calendar_month_rounded,
      label: '比赛时间',
      value: event.eventTimeText.trim(),
    );
  }
  if (event.sortMonth >= 1 && event.sortMonth <= 12) {
    return _CompetitionTimeLine(
      icon: Icons.event_note_rounded,
      label: '预计月份',
      value: '${event.sortMonth} 月左右',
    );
  }
  return null;
}

bool _containsAny(String value, List<String> keywords) {
  return keywords.any(value.contains);
}

String _deadlineText(CompetitionEvent event) {
  final dt = event.registrationEnd;
  if (dt != null) {
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }
  return event.registrationTimeText;
}

String _calendarItemTimeText(
  Map<String, dynamic> item,
  String dateKey,
  String textKey,
) {
  final rawDate = '${item[dateKey] ?? ''}'.trim();
  final parsed = DateTime.tryParse(rawDate);
  if (parsed != null) {
    return '${parsed.year}-${parsed.month.toString().padLeft(2, '0')}-${parsed.day.toString().padLeft(2, '0')}';
  }
  return '${item[textKey] ?? ''}'.trim();
}



String _timeStatusLabel(String value) {
  switch (value) {
    case 'confirmed':
      return '已确认';
    case 'estimated':
      return '预计时间';
    case 'historical':
      return '往年参考';
    case 'pending':
      return '待通知';
    default:
      return value.isEmpty ? '待通知' : value;
  }
}

String _sourceLabel(String value) {
  switch (value) {
    case 'school_catalog':
      return '学校目录';
    case 'ministry_list':
      return '官方榜单';
    case 'college_notice':
      return '学院通知';
    case 'enterprise':
      return '企业赛事';
    case 'industry_association':
      return '行业协会';
    case 'platform':
      return '平台赛事';
    case 'user_submitted':
      return '用户补充';
    case 'admin_manual':
      return '管理员精选';
    case 'ai_import':
      return 'AI导入';
    default:
      return value.isEmpty ? '未知来源' : value;
  }
}
