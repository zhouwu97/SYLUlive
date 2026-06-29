import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/competition.dart';
import '../providers/auth_provider.dart';
import '../utils/app_feedback.dart';

const _competitionBg = Color(0xFFFAF8FF);
const _competitionPrimary = Color(0xFF7367C6);
const _competitionPrimaryDark = Color(0xFF4F46A5);
const _competitionLight = Color(0xFFECE9FF);
const _competitionBorder = Color(0xFFE8E4F0);
const _competitionMuted = Color(0xFF8B8794);
const _competitionOrange = Color(0xFFF59E0B);
const _competitionDanger = Color(0xFFEF4444);

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
  int _total = 0;
  String? _categorySlug;
  final Set<String> _recommendations = {};
  final Set<String> _recognitions = {};
  final Set<String> _sources = {};
  int? _calendarCount;

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
    if (mounted) setState(() => _loading = true);
    final hasUser = context.read<AuthProvider>().user != null;
    try {
      final results = await Future.wait([
        _dio.get('/competitions/categories'),
        _dio.get('/competitions/events', queryParameters: _queryParams()),
      ]);
      int? calendarCount = _calendarCount;
      if (hasUser) {
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
        final eventData = results[1].data as Map<String, dynamic>;
        _events = ((eventData['items'] as List?) ?? [])
            .map((e) => CompetitionEvent.fromJson(e))
            .toList();
        _total = (eventData['total'] as num?)?.toInt() ?? _events.length;
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

  Map<String, dynamic> _queryParams() {
    return {
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
    parts.addAll(_recognitions.map(_recognitionLabel));
    parts.addAll(_sources.map(_sourceLabel));
    if (parts.isEmpty) return '全部比赛';
    if (parts.length <= 3) return parts.join(' · ');
    return '已选 ${parts.length} 项';
  }

  @override
  Widget build(BuildContext context) {
    final user = context.watch<AuthProvider>().user;
    return Scaffold(
      backgroundColor: _competitionBg,
      appBar: AppBar(
        backgroundColor: _competitionBg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        title: const Text('竞赛中心'),
        actions: [
          if (user?.isAdmin == true)
            TextButton.icon(
              onPressed: _openAdminImport,
              icon: const Icon(Icons.admin_panel_settings_outlined, size: 18),
              label: const Text('管理'),
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 32),
          children: [
            _buildHeroCard(),
            const SizedBox(height: 16),
            _buildSearchField(),
            const SizedBox(height: 12),
            _buildSectionTabs(),
            const SizedBox(height: 12),
            _buildFilterBar(),
            const SizedBox(height: 10),
            _buildListHeader(),
            const SizedBox(height: 10),
            if (_loading)
              const Padding(
                padding: EdgeInsets.only(top: 80),
                child: Center(
                  child: CircularProgressIndicator(
                    color: _competitionPrimary,
                  ),
                ),
              )
            else if (_events.isEmpty)
              _CompetitionEmptyState(
                title: '暂无官方比赛',
                message: '管理员还没有维护官方比赛库。你可以先通过分享码或 AI JSON 导入自己的比赛日历。',
                primaryText: '去导入',
                onPrimary: _openShareImport,
                secondaryText: '刷新',
                onSecondary: _load,
              )
            else
              ..._events.map(_buildEventCard),
          ],
        ),
      ),
    );
  }

  Widget _buildHeroCard() {
    final myCount = _calendarCount ?? 0;
    final pendingCount = _events.where((event) {
      final deadline = event.registrationEnd;
      return deadline != null && !deadline.isBefore(DateTime.now());
    }).length;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 15, 16, 16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF7C72D8), Color(0xFF6F66B8)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
            color: _competitionPrimary.withValues(alpha: 0.22),
            blurRadius: 24,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(13),
                ),
                child: const Icon(
                  Icons.emoji_events_rounded,
                  color: Colors.white,
                  size: 22,
                ),
              ),
              const Spacer(),
              Material(
                color: Colors.white.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(999),
                child: InkWell(
                  onTap: _openShareImport,
                  borderRadius: BorderRadius.circular(999),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    child: Text(
                      '导入',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Text(
            '比赛日历',
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w900,
              height: 1.1,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            '官方比赛、我的计划、分享导入统一管理',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.82),
              fontSize: 12.5,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 15),
          Row(
            children: [
              _heroStat('官方比赛', '$_total'),
              const SizedBox(width: 20),
              _heroStat('我的日历', '$myCount'),
              const SizedBox(width: 20),
              _heroStat('待截止', '$pendingCount'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _heroStat(String label, String value) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.72),
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchField() {
    return Container(
      height: 46,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(23),
        border: Border.all(color: _competitionBorder),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 14,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        children: [
          const Icon(Icons.search_rounded, color: _competitionMuted, size: 21),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _searchController,
              textInputAction: TextInputAction.search,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _load(),
              decoration: const InputDecoration(
                hintText: '搜索比赛、主办方、标签',
                hintStyle: TextStyle(color: _competitionMuted, fontSize: 14),
                border: InputBorder.none,
                isCollapsed: true,
              ),
              style: const TextStyle(fontSize: 14),
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
              icon: const Icon(Icons.close_rounded, size: 18),
            ),
        ],
      ),
    );
  }

  Widget _buildSectionTabs() {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: _competitionLight,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          _CompetitionSegment(
            label: '官方比赛',
            icon: Icons.workspace_premium_outlined,
            selected: true,
            onTap: _load,
          ),
          _CompetitionSegment(
            label: '我的日历',
            icon: Icons.event_available_outlined,
            selected: false,
            onTap: _openCalendar,
          ),
          _CompetitionSegment(
            label: '导入分享',
            icon: Icons.ios_share_outlined,
            selected: false,
            onTap: _openShareImport,
          ),
        ],
      ),
    );
  }

  Widget _buildFilterBar() {
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Row(
        children: [
          _SoftActionButton(
            icon: Icons.tune_rounded,
            label: '筛选分类',
            onTap: _openFilters,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _filterSummary,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: _competitionPrimaryDark,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          _SoftActionButton(
            icon: Icons.sort_rounded,
            label: '即将截止',
            onTap: () => AppFeedback.showSnackBar(context, '当前按报名截止时间排序'),
          ),
        ],
      ),
    );
  }

  Widget _buildListHeader() {
    return Row(
      children: [
        const Text(
          '官方比赛',
          style: TextStyle(
            fontWeight: FontWeight.w900,
            color: Color(0xFF252433),
          ),
        ),
        Text(
          ' · 共 $_total 个',
          style: const TextStyle(
            color: _competitionMuted,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
        const Spacer(),
        const Text(
          '即将截止',
          style: TextStyle(
            color: _competitionMuted,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }

  Widget _buildEventCard(CompetitionEvent event) {
    final deadline = _deadlineText(event);
    final level = [
      if (event.competitionLevel.isNotEmpty) event.competitionLevel,
      event.primaryCategory?.name ?? '未分类',
    ].join(' / ');
    final isClosed = event.registrationEnd != null &&
        event.registrationEnd!.isBefore(DateTime.now());

    return Container(
      margin: const EdgeInsets.only(top: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _competitionBorder),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.035),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: InkWell(
        onTap: () => _openDetail(event),
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      event.title,
                      style: const TextStyle(
                        fontSize: 16,
                        height: 1.25,
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF242330),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  _statusPill(
                    isClosed ? '已截止' : '即将截止',
                    isClosed ? _competitionDanger : _competitionOrange,
                  ),
                ],
              ),
              const SizedBox(height: 7),
              Text(
                level,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: _competitionPrimaryDark,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (event.organizer.isNotEmpty) ...[
                const SizedBox(height: 10),
                _eventInfo(
                    Icons.account_balance_outlined, '主办方', event.organizer),
              ],
              if (deadline.isNotEmpty)
                _eventInfo(Icons.alarm_rounded, '报名截止', deadline,
                    highlight: !isClosed),
              if (event.eventTimeText.isNotEmpty)
                _eventInfo(
                    Icons.calendar_month_rounded, '比赛时间', event.eventTimeText),
              const SizedBox(height: 12),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  _chip('${event.recommendationLevel}推荐'),
                  _chip(_recognitionLabel(event.schoolRecognitionStatus)),
                  _chip(_sourceLabel(event.sourceChannel)),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => _openDetail(event),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: _competitionPrimaryDark,
                        side: const BorderSide(color: _competitionBorder),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(13),
                        ),
                      ),
                      child: const Text('查看详情'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () => _copyToCalendar(event.id),
                      style: FilledButton.styleFrom(
                        backgroundColor: _competitionPrimary,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(13),
                        ),
                      ),
                      icon: const Icon(Icons.add_rounded, size: 18),
                      label: const Text('加入日历'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _eventInfo(
    IconData icon,
    String label,
    String value, {
    bool highlight = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(top: 7),
      child: Row(
        children: [
          Icon(
            icon,
            size: 15,
            color: highlight ? _competitionOrange : _competitionMuted,
          ),
          const SizedBox(width: 6),
          Text(
            '$label：',
            style: const TextStyle(
              color: _competitionMuted,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          Expanded(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: highlight ? _competitionOrange : const Color(0xFF444150),
                fontSize: 12,
                fontWeight: highlight ? FontWeight.w800 : FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusPill(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }

  Widget _chip(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: _competitionLight.withValues(alpha: 0.74),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: _competitionPrimaryDark,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Future<void> _copyToCalendar(int eventId) async {
    try {
      await _dio
          .post('/user/competition-calendar/items/copy-from-official/$eventId');
      if (!mounted) return;
      AppFeedback.showSnackBar(context, '已加入我的比赛日历');
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

  void _openAdminImport() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const CompetitionAdminImportScreen()),
    );
  }
}

class _CompetitionSegment extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const _CompetitionSegment({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Material(
        color: selected ? Colors.white : Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Container(
            height: 44,
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    icon,
                    size: 17,
                    color:
                        selected ? _competitionPrimaryDark : _competitionMuted,
                  ),
                  const SizedBox(width: 5),
                  Text(
                    label,
                    style: TextStyle(
                      color: selected
                          ? _competitionPrimaryDark
                          : _competitionMuted,
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SoftActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _SoftActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 11),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: _competitionBorder),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: _competitionPrimaryDark),
              const SizedBox(width: 5),
              Text(
                label,
                style: const TextStyle(
                  color: _competitionPrimaryDark,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CompetitionEmptyState extends StatelessWidget {
  final String title;
  final String message;
  final String primaryText;
  final VoidCallback onPrimary;
  final String secondaryText;
  final VoidCallback onSecondary;

  const _CompetitionEmptyState({
    required this.title,
    required this.message,
    required this.primaryText,
    required this.onPrimary,
    required this.secondaryText,
    required this.onSecondary,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 24),
      padding: const EdgeInsets.fromLTRB(18, 22, 18, 18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: _competitionBorder),
      ),
      child: Column(
        children: [
          Container(
            width: 58,
            height: 58,
            decoration: BoxDecoration(
              color: _competitionLight,
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Icon(
              Icons.emoji_events_outlined,
              color: _competitionPrimary,
              size: 30,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w900,
              color: Color(0xFF242330),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: _competitionMuted,
              fontSize: 13,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: onPrimary,
                  style: FilledButton.styleFrom(
                    backgroundColor: _competitionPrimary,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: Text(primaryText),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton(
                  onPressed: onSecondary,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _competitionPrimaryDark,
                    side: const BorderSide(color: _competitionBorder),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: Text(secondaryText),
                ),
              ),
            ],
          ),
        ],
      ),
    );
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
      _event = CompetitionEvent.fromJson(resp.data);
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final event = _event;
    return Scaffold(
      appBar: AppBar(title: const Text('比赛详情')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : event == null
              ? const Center(child: Text('比赛不存在'))
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Text(event.title,
                        style: const TextStyle(
                            fontSize: 22, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 10),
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      Chip(label: Text('${event.recommendationLevel}推荐')),
                      Chip(label: Text(event.primaryCategory?.name ?? '未分类')),
                      Chip(label: Text(_sourceLabel(event.sourceChannel))),
                    ]),
                    const SizedBox(height: 12),
                    _info('学校认定',
                        _recognitionLabel(event.schoolRecognitionStatus)),
                    _info('学校等级', event.schoolRecognitionGrade),
                    _info('报名截止', _deadlineText(event)),
                    _info('比赛时间', event.eventTimeText),
                    _info('比赛级别', event.competitionLevel),
                    _info('地点', event.isOnline ? '线上' : event.location),
                    if (event.recommendationReason.isNotEmpty)
                      _section('推荐说明', event.recommendationReason),
                    _section(
                        '比赛说明',
                        event.description.isNotEmpty
                            ? event.description
                            : event.summary),
                    _info('主办方', event.organizer),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: () => context.read<AuthProvider>().dio.post(
                          '/user/competition-calendar/items/copy-from-official/${event.id}'),
                      icon: const Icon(Icons.add),
                      label: const Text('加入我的日历'),
                    ),
                    if (event.officialUrl.isNotEmpty)
                      OutlinedButton.icon(
                        onPressed: () =>
                            launchUrl(Uri.parse(event.officialUrl)),
                        icon: const Icon(Icons.open_in_new),
                        label: const Text('打开官网'),
                      ),
                  ],
                ),
    );
  }
}

Widget _info(String label, String value) {
  if (value.trim().isEmpty) return const SizedBox.shrink();
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Text('$label：$value'),
  );
}

Widget _section(String title, String value) {
  if (value.trim().isEmpty) return const SizedBox.shrink();
  return Padding(
    padding: const EdgeInsets.only(top: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        Text(value, style: const TextStyle(height: 1.6)),
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
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final resp = await context
        .read<AuthProvider>()
        .dio
        .get('/user/competition-calendar');
    if (!mounted) return;
    setState(() {
      _items = (resp.data['items'] as List?) ?? [];
      _loading = false;
    });
  }

  Future<void> _share() async {
    final resp = await context
        .read<AuthProvider>()
        .dio
        .post('/user/competition-calendar/share');
    if (!mounted) return;
    AppFeedback.showSnackBar(context, '分享码：${resp.data['share_code']}');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _competitionBg,
      appBar: AppBar(
        backgroundColor: _competitionBg,
        surfaceTintColor: Colors.transparent,
        centerTitle: true,
        title: const Text('我的比赛日历'),
        actions: [
          IconButton(onPressed: _share, icon: const Icon(Icons.ios_share)),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text('已加入比赛 ${_items.length} 个',
                    style: const TextStyle(fontWeight: FontWeight.w800)),
                const SizedBox(height: 12),
                if (_items.isEmpty)
                  _CompetitionEmptyState(
                    title: '你的比赛日历还是空的',
                    message: '可以从官方比赛复制到日历，也可以通过 AI JSON 或分享码导入自己的参赛计划。',
                    primaryText: '去导入',
                    onPrimary: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const CompetitionShareImportScreen(),
                      ),
                    ).then((_) => _load()),
                    secondaryText: '刷新',
                    onSecondary: _load,
                  ),
                ..._items.map((raw) {
                  final item = Map<String, dynamic>.from(raw as Map);
                  return Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: _competitionBorder),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: _competitionLight,
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: const Text(
                                '我的日历',
                                style: TextStyle(
                                  color: _competitionPrimaryDark,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                            const Spacer(),
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () async {
                                await context.read<AuthProvider>().dio.delete(
                                      '/user/competition-calendar/items/${item['id']}',
                                    );
                                _load();
                              },
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          item['title'] ?? '',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w900,
                            color: Color(0xFF242330),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '报名截止：${item['registration_time_text'] ?? '未设置'}',
                          style: const TextStyle(
                            color: _competitionOrange,
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '来源：${item['source_type'] ?? '我的导入'}',
                          style: const TextStyle(
                            color: _competitionMuted,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  );
                }),
              ],
            ),
    );
  }
}

class CompetitionShareImportScreen extends StatefulWidget {
  const CompetitionShareImportScreen({super.key});

  @override
  State<CompetitionShareImportScreen> createState() =>
      _CompetitionShareImportScreenState();
}

class _CompetitionShareImportScreenState
    extends State<CompetitionShareImportScreen> {
  final _controller = TextEditingController();
  Map<String, dynamic>? _preview;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _previewShare() async {
    final resp = await context.read<AuthProvider>().dio.post(
      '/user/competition-calendar/import-share/preview',
      data: {'share_code': _controller.text.trim()},
    );
    if (!mounted) return;
    setState(() => _preview = Map<String, dynamic>.from(resp.data));
  }

  Future<void> _commit(String strategy) async {
    await context.read<AuthProvider>().dio.post(
      '/user/competition-calendar/import-share/commit',
      data: {'share_code': _controller.text.trim(), 'strategy': strategy},
    );
    if (!mounted) return;
    AppFeedback.showSnackBar(context, '导入完成');
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final items = (_preview?['items'] as List?) ?? [];
    return Scaffold(
      appBar: AppBar(title: const Text('导入分享')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _controller,
            decoration: const InputDecoration(labelText: '分享码'),
          ),
          const SizedBox(height: 12),
          FilledButton(onPressed: _previewShare, child: const Text('预览')),
          if (_preview != null) ...[
            const SizedBox(height: 16),
            Text('预览 ${items.length} 个比赛',
                style: const TextStyle(fontWeight: FontWeight.w800)),
            ...items.map((e) => ListTile(title: Text(e['title'] ?? ''))),
            Row(children: [
              Expanded(
                  child: OutlinedButton(
                      onPressed: () => _commit('merge'),
                      child: const Text('合并'))),
              const SizedBox(width: 10),
              Expanded(
                  child: FilledButton(
                      onPressed: () => _commit('replace'),
                      child: const Text('覆盖'))),
            ]),
          ],
        ],
      ),
    );
  }
}

class CompetitionAdminImportScreen extends StatefulWidget {
  const CompetitionAdminImportScreen({super.key});

  @override
  State<CompetitionAdminImportScreen> createState() =>
      _CompetitionAdminImportScreenState();
}

class _CompetitionAdminImportScreenState
    extends State<CompetitionAdminImportScreen> {
  final _jsonController = TextEditingController();
  String? _batchId;
  Map<String, dynamic>? _preview;

  @override
  void dispose() {
    _jsonController.dispose();
    super.dispose();
  }

  Future<void> _previewJson() async {
    final data = jsonDecode(_jsonController.text) as Map<String, dynamic>;
    final resp = await context
        .read<AuthProvider>()
        .dio
        .post('/admin/competitions/import-json/preview', data: data);
    if (!mounted) return;
    setState(() {
      _batchId = resp.data['batch_id'];
      _preview = Map<String, dynamic>.from(resp.data['preview']);
    });
  }

  Future<void> _commit() async {
    final count = (_preview?['item_count'] as num?)?.toInt() ?? 0;
    await context.read<AuthProvider>().dio.post(
      '/admin/competitions/import-json/commit',
      data: {
        'batch_id': _batchId,
        'selected_actions': [
          for (var i = 0; i < count; i++) {'index': i, 'action': 'create'}
        ],
      },
    );
    if (!mounted) return;
    AppFeedback.showSnackBar(context, 'AI 导入已提交，默认进入草稿');
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('AI 辅助导入比赛')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _jsonController,
            minLines: 12,
            maxLines: 24,
            decoration: const InputDecoration(
              labelText: '粘贴 AI 输出 JSON',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(onPressed: _previewJson, child: const Text('提交预览')),
          if (_preview != null) ...[
            const SizedBox(height: 16),
            Text('batch_id：$_batchId'),
            Text(
                '条目：${_preview!['item_count']}，有效：${_preview!['valid_count']}'),
            if ((_preview!['errors'] as List).isNotEmpty)
              Text('错误：${jsonEncode(_preview!['errors'])}'),
            const SizedBox(height: 12),
            FilledButton(onPressed: _commit, child: const Text('确认入库')),
          ],
        ],
      ),
    );
  }
}

String _deadlineText(CompetitionEvent event) {
  final dt = event.registrationEnd;
  if (dt != null) {
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }
  return event.registrationTimeText;
}

String _recognitionLabel(String value) {
  switch (value) {
    case 'recognized':
      return '已认定';
    case 'not_recognized':
      return '未认定';
    case 'pending':
      return '待确认';
    case 'unknown':
      return '未知';
    default:
      return value.isEmpty ? '未知' : value;
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
