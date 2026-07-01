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

const _competitionAiPrompt = '''
你是校园竞赛信息整理助手。请把我提供的比赛通知整理成校园 App 可导入的 JSON。

只允许输出 JSON，不要输出 Markdown，不要解释，不要使用 ``` 包裹。

重要规则：
1. 不要编造精确日期。
2. 能确定到日，才填写 YYYY-MM-DD。
3. 只能确定月份，就填写 sort_month，并把日期字段留空。
4. 根据往年经验判断，time_status 填 historical。
5. 官方通知已经明确日期，time_status 填 confirmed。
6. 只是预计时间，time_status 填 estimated。
7. 完全不知道时间，time_status 填 pending。
8. time_note 必须说明时间来源。
9. 学校认定不确定时，school_recognition_status 用 pending 或 unknown，禁止编造 recognized。

固定格式如下：
{
  "events": [
    {
      "title": "比赛名称",
      "summary": "一句话摘要，80字以内",
      "description": "比赛说明，可包含报名方式、参赛对象、赛程等",
      "primary_category_slug": "分类slug，必须使用系统已有分类：$_competitionCategorySlugHint",
      "tags": ["数学建模", "创新创业"],
      "competition_level": "国家级/省级/校级/企业赛/平台赛/其他",
      "school_recognition_status": "recognized/not_recognized/pending/unknown",
      "school_recognition_grade": "",
      "recommendation_level": "S/A/B/C",
      "importance_score": 80,
      "recommendation_reason": "推荐理由，60字以内",
      "organizer": "主办方",
      "host_unit": "承办/指导单位，没有就空字符串",
      "target_audience": "参赛对象",
      "participation_type": "个人/团队/个人或团队",
      "team_size_min": 1,
      "team_size_max": 5,
      "registration_start": "YYYY-MM-DD，不确定填空字符串",
      "registration_end": "YYYY-MM-DD，不确定填空字符串",
      "event_start": "YYYY-MM-DD，不确定填空字符串",
      "event_end": "YYYY-MM-DD，不确定填空字符串",
      "registration_time_text": "原文报名时间描述",
      "event_time_text": "原文比赛时间描述",
      "time_precision": "exact/month/month_range/quarter/half_year/season/unknown",
      "time_status": "confirmed/estimated/historical/pending",
      "time_note": "说明时间来源，例如官方通知、往年参考、等待学校通知",
      "sort_month": 0,
      "location": "地点，没有填空字符串",
      "is_online": false,
      "official_url": "官网链接，没有填空字符串",
      "notice_url": "通知链接，没有填空字符串",
      "attachment_urls": [],
      "source_channel": "school_catalog/college_notice/enterprise/industry_association/platform/admin_manual/ai_import",
      "source_note": "来源说明",
      "status": "draft"
    }
  ]
}

规则：
1. 日期字段必须是 YYYY-MM-DD，不能确定就留空字符串。
2. URL 必须是 http 或 https，不确定就留空字符串。
3. recommendation_level 只能是 S/A/B/C。
4. school_recognition_status 只能是 recognized/not_recognized/pending/unknown。
5. source_channel 优先用 college_notice、school_catalog、enterprise、platform。
6. primary_category_slug 必须使用系统已有分类：$_competitionCategorySlugHint。
7. time_precision 只能用 exact/month/month_range/quarter/half_year/season/unknown。
8. time_status 只能用 confirmed/estimated/historical/pending。
''';

const _competitionAiExampleJson = '''
{
  "events": [
    {
      "title": "蓝桥杯全国软件和信息技术专业人才大赛",
      "summary": "面向程序设计、电子、视觉艺术等方向的综合竞赛。",
      "description": "适合有编程、电子或设计基础的学生参加。",
      "primary_category_slug": "computer_ai",
      "tags": ["算法", "个人赛", "程序设计"],
      "competition_level": "国家级",
      "school_recognition_status": "pending",
      "school_recognition_grade": "",
      "recommendation_level": "A",
      "importance_score": 85,
      "recommendation_reason": "个人能力占比较高，高等级奖项仍需要长期训练。",
      "organizer": "相关主办单位",
      "host_unit": "",
      "target_audience": "在校大学生",
      "participation_type": "个人",
      "team_size_min": 1,
      "team_size_max": 1,
      "registration_start": "",
      "registration_end": "",
      "event_start": "",
      "event_end": "",
      "registration_time_text": "往年一般在每年秋季至次年初报名，具体以当年通知为准",
      "event_time_text": "省赛一般在春季，国赛时间以官方通知为准",
      "time_precision": "month_range",
      "time_status": "historical",
      "time_note": "未找到今年正式通知，时间根据往年公开信息整理",
      "sort_month": 10,
      "location": "",
      "is_online": false,
      "official_url": "",
      "notice_url": "",
      "attachment_urls": [],
      "source_channel": "ai_import",
      "source_note": "AI 根据公开资料整理，需管理员确认",
      "status": "draft"
    }
  ]
}
''';

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
              icon: const Icon(Icons.auto_awesome_rounded, size: 18),
              label: const Text('AI导入'),
            ),
        ],
      ),
      body: Column(
        children: [
          _buildHeroCard(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: _buildSearchField(),
          ),
          const SizedBox(height: 12),
          _buildFilterBar(),
          const SizedBox(height: 12),
          Expanded(
            child: _loading
                ? const Center(
                    child: CircularProgressIndicator(
                      color: _competitionPrimary,
                    ),
                  )
                : _events.isEmpty
                    ? SingleChildScrollView(
                        child: _CompetitionEmptyState(
                          title: user?.isAdmin == true
                              ? '官方比赛库还没有内容'
                              : '暂时没有官方推荐比赛',
                          message: user?.isAdmin == true
                              ? '官方比赛库还没有内容。建议先导入一批长期稳定比赛，再逐步补充今年通知。'
                              : '暂时没有官方推荐比赛。你可以先导入同学整理的计划，或手动添加想关注的比赛。',
                          primaryText: user?.isAdmin == true ? 'AI导入' : '导入计划',
                          onPrimary: user?.isAdmin == true
                              ? _openAdminImport
                              : _openShareImport,
                          secondaryText: user?.isAdmin == true ? '新建比赛' : '刷新',
                          onSecondary:
                              user?.isAdmin == true ? _openAdminImport : _load,
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: _load,
                        child: ListView(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
                          children: _events.map(_buildEventCard).toList(),
                        ),
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeroCard() {
    final myCount = _calendarCount ?? 0;
    final pendingCount =
        _events.where((event) => event.registrationEnd == null).length;
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 6, 20, 10),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF7C72D8), Color(0xFF6F66B8)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: _competitionPrimary.withValues(alpha: 0.20),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '竞赛中心',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        height: 1.1,
                      ),
                    ),
                    SizedBox(height: 6),
                    Text(
                      '发现比赛 / 加入计划 / 等待通知更新',
                      style: TextStyle(
                        color: Color(0xFFE8E3FF),
                        fontSize: 13,
                        height: 1.2,
                      ),
                    ),
                  ],
                ),
              ),
              _buildImportButton(),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _buildStatItem(
                  value: _total,
                  label: '推荐比赛',
                ),
              ),
              Expanded(
                child: _buildStatItem(
                  value: myCount,
                  label: '我的计划',
                  onTap: _openCalendar,
                  showChevron: true,
                ),
              ),
              Expanded(
                child: _buildStatItem(
                  value: pendingCount,
                  label: '时间待确认',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildImportButton() {
    return Material(
      color: Colors.white.withValues(alpha: 0.92),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        onTap: _openShareImport,
        borderRadius: BorderRadius.circular(999),
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          child: Text(
            '导入',
            style: TextStyle(
              color: _competitionPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStatItem({
    required int value,
    required String label,
    VoidCallback? onTap,
    bool showChevron = false,
  }) {
    final child = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '$value',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 19,
                fontWeight: FontWeight.w800,
                height: 1,
              ),
            ),
            if (showChevron) ...[
              const SizedBox(width: 3),
              Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: Colors.white.withValues(alpha: 0.75),
              ),
            ],
          ],
        ),
        const SizedBox(height: 5),
        Text(
          label,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.78),
            fontSize: 11,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );

    if (onTap == null) return child;

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: child,
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
                hintText: '搜索比赛名称 / 主办方 / 标签',
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

  Widget _buildFilterBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: SizedBox(
        height: 40,
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
              label: '时间状态',
              onTap: () => AppFeedback.showSnackBar(context, '当前按时间安排排序'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEventCard(CompetitionEvent event) {
    final timeState = _competitionTimeState(event);
    final timeLine = _competitionTimeLine(event);
    final level = [
      if (event.competitionLevel.isNotEmpty) event.competitionLevel,
      event.primaryCategory?.name ?? '未分类',
    ].join(' / ');

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
                    timeState.label,
                    timeState.color,
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
              if (timeLine != null)
                _eventInfo(timeLine.icon, timeLine.label, timeLine.value,
                    highlight: timeState.highlight),
              if (event.eventTimeText.isNotEmpty && timeLine?.label != '比赛时间')
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
                      label: const Text('加入计划'),
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

  void _openAdminImport() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const CompetitionAdminImportScreen()),
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
      margin: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 22),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0xFFE7E1FA)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.025),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        children: [
          Container(
            width: 58,
            height: 58,
            decoration: BoxDecoration(
              color: const Color(0xFFEDE7FF),
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Icon(
              Icons.emoji_events_outlined,
              color: Color(0xFF7563D8),
              size: 30,
            ),
          ),
          const SizedBox(height: 18),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w800,
              color: Color(0xFF1F1D2B),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Color(0xFF8D879B),
              fontSize: 13,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 22),
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
              const SizedBox(width: 12),
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
                          _recognitionLabel(event.schoolRecognitionStatus),
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
    final items = _calendarItems;
    final grouped = _groupCalendarItems(items);
    final preparingCount =
        items.where((item) => _calendarPlanStatus(item) == 'preparing').length;
    final pendingCount = items
        .where((item) =>
            _calendarTimeStatus(item) == 'pending' &&
            _parseCalendarDate(item['registration_end']) == null)
        .length;
    return Scaffold(
      backgroundColor: _competitionBg,
      appBar: AppBar(
        backgroundColor: _competitionBg,
        surfaceTintColor: Colors.transparent,
        centerTitle: true,
        title: const Text('我的竞赛计划'),
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
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _buildPlanSummary(
                  total: items.length,
                  preparing: preparingCount,
                  pending: pendingCount,
                ),
                const SizedBox(height: 12),
                if (items.isEmpty)
                  _CompetitionEmptyState(
                    title: '还没有加入竞赛计划',
                    message: '时间不确定也可以先关注比赛，后续看到学校通知后再补充准确时间。',
                    primaryText: '去发现比赛',
                    onPrimary: () => Navigator.maybePop(context),
                    secondaryText: '手动添加',
                    onSecondary: () => _openEditor(),
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

  Widget _buildPlanSummary({
    required int total,
    required int preparing,
    required int pending,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _competitionBorder),
      ),
      child: Row(
        children: [
          Expanded(child: _summaryValue('已关注', total)),
          Expanded(child: _summaryValue('准备中', preparing)),
          Expanded(child: _summaryValue('待通知', pending)),
        ],
      ),
    );
  }

  Widget _summaryValue(String label, int value) {
    return Column(
      children: [
        Text(
          '$value',
          style: const TextStyle(
            color: _competitionPrimaryDark,
            fontSize: 18,
            fontWeight: FontWeight.w900,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          label,
          style: const TextStyle(
            color: _competitionMuted,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }

  Widget _buildPlanGroup(String title, List<Map<String, dynamic>> items) {
    if (items.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 8, 2, 6),
            child: Text(
              title,
              style: const TextStyle(
                color: Color(0xFF242330),
                fontSize: 15,
                fontWeight: FontWeight.w900,
              ),
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
    final source = _calendarItemSourceLabel('${item['source_type'] ?? ''}');
    final planStatus = _calendarPlanStatus(item);
    final timeStatus = _calendarTimeStatus(item);
    final userNote = '${item['user_note'] ?? ''}'.trim();
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
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _planChip(_planStatusLabel(planStatus)),
              _planChip(_timeStatusLabel(timeStatus)),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            '${item['title'] ?? ''}',
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w900,
              color: Color(0xFF242330),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '报名安排：${deadline.isEmpty ? '时间待通知' : deadline}',
            style: const TextStyle(
              color: _competitionOrange,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '来源：$source',
            style: const TextStyle(color: _competitionMuted, fontSize: 12),
          ),
          if (userNote.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              '我的备注：$userNote',
              style: const TextStyle(color: _competitionMuted, fontSize: 12),
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _openEditor(item: item),
                  icon: const Icon(Icons.edit_outlined, size: 17),
                  label: const Text('编辑'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _deleteItem(item),
                  icon: const Icon(Icons.delete_outline, size: 17),
                  label: const Text('删除'),
                ),
              ),
              if (planStatus != 'archived') ...[
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () => _archiveItem(item),
                    icon: const Icon(Icons.archive_outlined, size: 17),
                    label: const Text('归档'),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
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

  Widget _planChip(String label) {
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
          fontWeight: FontWeight.w800,
        ),
      ),
    );
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
    return Scaffold(
      backgroundColor: _competitionBg,
      appBar: AppBar(
        backgroundColor: _competitionBg,
        surfaceTintColor: Colors.transparent,
        centerTitle: true,
        title: Text(_isEditing ? '编辑比赛' : '新增比赛'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          _input(_titleController, '比赛名称', required: true),
          const SizedBox(height: 12),
          DropdownButtonFormField<int>(
            initialValue: _categoryId,
            decoration: _inputDecoration('比赛分类'),
            items: widget.categories
                .map(
                  (category) => DropdownMenuItem(
                    value: category.id,
                    child: Text(category.name),
                  ),
                )
                .toList(),
            onChanged: (value) => setState(() => _categoryId = value),
          ),
          const SizedBox(height: 12),
          _input(_summaryController, '一句话摘要'),
          const SizedBox(height: 12),
          _input(_descriptionController, '比赛说明', minLines: 4, maxLines: 8),
          const SizedBox(height: 12),
          _input(_organizerController, '主办方'),
          const SizedBox(height: 12),
          _input(_competitionLevelController, '比赛级别'),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: _recommendation,
                  decoration: _inputDecoration('推荐程度'),
                  items: const [
                    DropdownMenuItem(value: 'S', child: Text('S 强烈推荐')),
                    DropdownMenuItem(value: 'A', child: Text('A 推荐')),
                    DropdownMenuItem(value: 'B', child: Text('B 可参加')),
                    DropdownMenuItem(value: 'C', child: Text('C 兴趣')),
                  ],
                  onChanged: (value) =>
                      setState(() => _recommendation = value ?? 'A'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: _recognition,
                  decoration: _inputDecoration('学校认定'),
                  items: const [
                    DropdownMenuItem(value: 'recognized', child: Text('已认定')),
                    DropdownMenuItem(
                        value: 'not_recognized', child: Text('未认定')),
                    DropdownMenuItem(value: 'pending', child: Text('待确认')),
                    DropdownMenuItem(value: 'unknown', child: Text('未知')),
                  ],
                  onChanged: (value) =>
                      setState(() => _recognition = value ?? 'pending'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _input(_registrationEndController, '报名截止日期 YYYY-MM-DD'),
          const SizedBox(height: 12),
          _input(_registrationTextController, '报名时间说明'),
          const SizedBox(height: 12),
          _input(_eventStartController, '比赛开始日期 YYYY-MM-DD'),
          const SizedBox(height: 12),
          _input(_eventTextController, '比赛时间说明'),
          const SizedBox(height: 12),
          SwitchListTile(
            value: _isOnline,
            onChanged: (value) => setState(() => _isOnline = value),
            title: const Text('线上比赛'),
            contentPadding: EdgeInsets.zero,
            activeThumbColor: _competitionPrimary,
          ),
          _input(_locationController, '地点'),
          const SizedBox(height: 12),
          _input(_officialUrlController, '官网链接'),
          const SizedBox(height: 12),
          _input(_noticeUrlController, '通知链接'),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _saving ? null : _save,
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
              backgroundColor: _competitionPrimary,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(15),
              ),
            ),
            child: Text(_saving ? '保存中...' : '保存'),
          ),
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
  }) {
    return TextField(
      controller: controller,
      minLines: minLines,
      maxLines: maxLines,
      decoration: _inputDecoration(required ? '$label *' : label),
    );
  }

  InputDecoration _inputDecoration(String label) {
    return InputDecoration(
      labelText: label,
      filled: true,
      fillColor: Colors.white,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: _competitionBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: _competitionBorder),
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
        AppFeedback.showSnackBar(
          context,
          '读取文件失败，请重新选择 JSON 文件',
          isError: true,
        );
        return;
      }

      final text = utf8.decode(bytes).trim();
      final decoded = jsonDecode(text);

      if (decoded is! Map<String, dynamic> || decoded['events'] is! List) {
        AppFeedback.showSnackBar(
          context,
          'JSON 顶层必须是 {"events": [...]}',
          isError: true,
        );
        return;
      }

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
  String? _previewedJsonText;
  String? _jsonFileName;
  bool _readingJsonFile = false;

  @override
  void initState() {
    super.initState();
    _jsonController.addListener(_handleJsonChanged);
  }

  @override
  void dispose() {
    _jsonController.removeListener(_handleJsonChanged);
    _jsonController.dispose();
    super.dispose();
  }

  void _handleJsonChanged() {
    if (_preview == null && _batchId == null && _previewedJsonText == null) {
      return;
    }
    if (_jsonController.text == _previewedJsonText) {
      return;
    }
    setState(() {
      _preview = null;
      _batchId = null;
      _previewedJsonText = null;
    });
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
        AppFeedback.showSnackBar(
          context,
          '读取文件失败，请重新选择 JSON 文件',
          isError: true,
        );
        return;
      }

      final decoded = jsonDecode(text);

      if (decoded is! Map<String, dynamic> || decoded['events'] is! List) {
        AppFeedback.showSnackBar(
          context,
          'JSON 顶层必须是 {"events": [...]}',
          isError: true,
        );
        return;
      }

      const encoder = JsonEncoder.withIndent('  ');

      setState(() {
        _jsonFileName = file.name;
        _jsonController.text = encoder.convert(decoded);
        _preview = null;
        _batchId = null;
        _previewedJsonText = null;
      });

      AppFeedback.showSnackBar(context, '已读取 ${file.name}');
    } on FormatException {
      AppFeedback.showSnackBar(
        context,
        'JSON 格式不正确，请检查逗号、引号和括号',
        isError: true,
      );
    } catch (e) {
      AppFeedback.showSnackBar(
        context,
        '读取 JSON 文件失败：$e',
        isError: true,
      );
    } finally {
      if (mounted) {
        setState(() => _readingJsonFile = false);
      }
    }
  }

  List<Map<String, dynamic>> get _draftEvents {
    try {
      final data = jsonDecode(_jsonController.text);
      if (data is! Map<String, dynamic>) return [];
      final events = data['events'];
      if (events is! List) return [];
      return events
          .whereType<Map>()
          .map((event) => Map<String, dynamic>.from(event))
          .toList();
    } catch (_) {
      return [];
    }
  }

  List<Map<String, dynamic>> get _sortedDraftEvents {
    final indexed = _draftEvents.asMap().entries.toList();
    indexed.sort((left, right) {
      final leftDate = _draftSortDate(left.value);
      final rightDate = _draftSortDate(right.value);
      if (leftDate != null && rightDate != null) {
        final compared = leftDate.compareTo(rightDate);
        if (compared != 0) return compared;
      } else if (leftDate != null) {
        return -1;
      } else if (rightDate != null) {
        return 1;
      }
      return left.key.compareTo(right.key);
    });
    return indexed.map((entry) => entry.value).toList();
  }

  bool get _canCommitPreview {
    final errors = (_preview?['errors'] as List?) ?? [];
    return _batchId != null &&
        _preview != null &&
        _previewedJsonText == _jsonController.text &&
        errors.isEmpty;
  }

  Future<void> _previewJson() async {
    try {
      final decoded = jsonDecode(_jsonController.text);
      if (decoded is! Map<String, dynamic>) {
        AppFeedback.showSnackBar(
          context,
          'JSON 顶层必须是 {"events": [...]}',
          isError: true,
        );
        return;
      }
      final resp = await context
          .read<AuthProvider>()
          .dio
          .post('/admin/competitions/import-json/preview', data: decoded);
      if (!mounted) return;
      setState(() {
        _batchId = resp.data['batch_id'];
        _preview = Map<String, dynamic>.from(resp.data['preview']);
        _previewedJsonText = _jsonController.text;
      });
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
        AppFeedback.dioErrorMessage(e, fallback: '提交预览失败'),
        isError: true,
      );
    } catch (_) {
      if (!mounted) return;
      AppFeedback.showSnackBar(
        context,
        '提交预览失败，请检查 JSON 格式',
        isError: true,
      );
    }
  }

  Future<void> _commit() async {
    final count = (_preview?['item_count'] as num?)?.toInt() ?? 0;
    try {
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
    } on DioException catch (e) {
      if (!mounted) return;
      AppFeedback.showSnackBar(
        context,
        AppFeedback.dioErrorMessage(e, fallback: '确认入库失败'),
        isError: true,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _competitionBg,
      appBar: AppBar(
        backgroundColor: _competitionBg,
        surfaceTintColor: Colors.transparent,
        centerTitle: true,
        title: const Text('AI 辅助导入比赛'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
        children: [
          _buildPromptCard(),
          const SizedBox(height: 12),
          _buildJsonFileImportCard(),
          const SizedBox(height: 12),
          TextField(
            controller: _jsonController,
            minLines: 8,
            maxLines: 16,
            decoration: InputDecoration(
              labelText: 'AI 生成的 JSON',
              hintText: '可以粘贴，也可以从上方选择 .json 文件',
              filled: true,
              fillColor: Colors.white,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(18),
                borderSide: const BorderSide(color: _competitionBorder),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(18),
                borderSide: const BorderSide(color: _competitionBorder),
              ),
              alignLabelWithHint: true,
            ),
            style: const TextStyle(fontSize: 13, height: 1.45),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () {
                    _jsonController.text = _competitionAiExampleJson;
                    AppFeedback.showSnackBar(context, '已填入示例 JSON');
                  },
                  icon: const Icon(Icons.data_object_rounded, size: 18),
                  label: const Text('填入示例'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _previewJson,
                  icon: const Icon(Icons.fact_check_outlined, size: 18),
                  label: const Text('检查预览'),
                ),
              ),
            ],
          ),
          if (_preview != null) ...[
            const SizedBox(height: 16),
            _buildPreviewCard(),
          ],
        ],
      ),
    );
  }

  Widget _buildJsonFileImportCard() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _competitionBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '也可以直接导入 JSON 文件',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w900,
              color: Color(0xFF242330),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            _jsonFileName == null
                ? '适合 100 条以上的大 JSON，不用再复制粘贴。'
                : '当前文件：$_jsonFileName',
            style: const TextStyle(
              color: _competitionMuted,
              fontSize: 12,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _readingJsonFile ? null : _pickJsonFile,
            icon: const Icon(Icons.upload_file_rounded, size: 18),
            label: Text(_readingJsonFile ? '读取中...' : '选择 JSON 文件'),
          ),
        ],
      ),
    );
  }

  Widget _buildPromptCard() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _competitionBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: _competitionLight,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.auto_awesome_rounded,
                  color: _competitionPrimary,
                  size: 19,
                ),
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  '先复制提示词给 AI',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                    color: Color(0xFF242330),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Text(
            '把比赛通知、官网链接或公告原文一起发给 AI，让它只输出固定 JSON。然后把 JSON 粘贴到下面检查预览。',
            style: TextStyle(
              color: _competitionMuted,
              fontSize: 13,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            '维护建议：先维护长期稳定比赛和待更新条目，学校集中通知时再补充今年的链接和截止日期。',
            style: TextStyle(
              color: _competitionPrimaryDark,
              fontSize: 12,
              height: 1.4,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'AI 不需要猜具体日期。不确定时间请标记为预计 / 往年参考 / 待通知，管理员确认后才会进入官方库。',
            style: TextStyle(
              color: _competitionOrange,
              fontSize: 12,
              height: 1.4,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            '分类 slug 必须使用系统已有分类；当前可用：$_competitionCategorySlugHint。',
            style: TextStyle(
              color: _competitionMuted,
              fontSize: 12,
              height: 1.4,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(
                      const ClipboardData(text: _competitionAiPrompt),
                    );
                    if (!mounted) return;
                    AppFeedback.showSnackBar(context, '已复制 AI 导入提示词');
                  },
                  icon: const Icon(Icons.copy_rounded, size: 17),
                  label: const Text('复制提示词'),
                  style: FilledButton.styleFrom(
                    backgroundColor: _competitionPrimary,
                    foregroundColor: Colors.white,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(
                      const ClipboardData(text: _competitionAiExampleJson),
                    );
                    if (!mounted) return;
                    AppFeedback.showSnackBar(context, '已复制示例 JSON');
                  },
                  icon: const Icon(Icons.content_paste_rounded, size: 17),
                  label: const Text('复制示例'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPreviewCard() {
    final errors = (_preview?['errors'] as List?) ?? [];
    final warnings = (_preview?['warnings'] as List?) ?? [];
    final draftEvents = _sortedDraftEvents;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _competitionBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '预览结果',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w900,
              color: Color(0xFF242330),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _previewPill('条目', '${_preview!['item_count'] ?? 0}'),
              const SizedBox(width: 8),
              _previewPill('有效', '${_preview!['valid_count'] ?? 0}'),
              const SizedBox(width: 8),
              _previewPill('错误', '${errors.length}'),
              const SizedBox(width: 8),
              _previewPill('警告', '${warnings.length}'),
            ],
          ),
          if (errors.isNotEmpty) ...[
            const SizedBox(height: 12),
            ...errors.map(
              (error) => Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  _previewErrorText(error),
                  style: const TextStyle(
                    color: _competitionDanger,
                    fontSize: 12,
                    height: 1.35,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
          if (warnings.isNotEmpty) ...[
            const SizedBox(height: 12),
            ...warnings.map(
              (warning) => Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  _previewErrorText(warning),
                  style: const TextStyle(
                    color: _competitionOrange,
                    fontSize: 12,
                    height: 1.35,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
          if (draftEvents.isNotEmpty) ...[
            const SizedBox(height: 14),
            const Text(
              '计划预览',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w900,
                color: Color(0xFF242330),
              ),
            ),
            const SizedBox(height: 8),
            ...draftEvents.map(_buildDraftEventCard),
          ],
          const SizedBox(height: 14),
          FilledButton(
            onPressed: _canCommitPreview ? _commit : null,
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(46),
              backgroundColor: _competitionPrimary,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(15),
              ),
            ),
            child: const Text('确认入库草稿'),
          ),
        ],
      ),
    );
  }

  Widget _previewPill(String label, String value) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: _competitionLight.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          children: [
            Text(
              value,
              style: const TextStyle(
                color: _competitionPrimaryDark,
                fontSize: 17,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              label,
              style: const TextStyle(
                color: _competitionMuted,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDraftEventCard(Map<String, dynamic> event) {
    final title = _draftValue(event, 'title');
    final category = _draftValue(event, 'primary_category_slug');
    final recommendation = _draftValue(event, 'recommendation_level');
    final recognition = _recognitionLabel(
      _draftValue(event, 'school_recognition_status'),
    );
    final organizer = _draftValue(event, 'organizer');
    final source = _sourceLabel(_draftValue(event, 'source_channel'));
    final timeStatus = _timeStatusLabel(_draftValue(event, 'time_status'));
    final timeNote = _draftValue(event, 'time_note');
    final sortMonth = _draftValue(event, 'sort_month');
    final hasExactDate = _draftValue(event, 'registration_end').isNotEmpty ||
        _draftValue(event, 'event_start').isNotEmpty;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _competitionBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _competitionBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title.isEmpty ? '未命名比赛' : title,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w900,
              color: Color(0xFF242330),
            ),
          ),
          const SizedBox(height: 8),
          _draftLine(
            Icons.alarm_rounded,
            '报名截止',
            _draftTimeText(event, 'registration_end', 'registration_time_text'),
          ),
          _draftLine(
            Icons.calendar_month_rounded,
            '比赛时间',
            _draftTimeText(event, 'event_start', 'event_time_text'),
          ),
          _draftLine(Icons.verified_outlined, '时间状态', timeStatus),
          _draftLine(
            Icons.event_note_rounded,
            '预计月份',
            sortMonth.isEmpty || sortMonth == '0' ? '未填写' : '$sortMonth 月',
          ),
          _draftLine(
            Icons.rule_rounded,
            '日期精度',
            hasExactDate ? '包含精确日期' : '未填写精确日期',
          ),
          if (timeNote.isNotEmpty)
            _draftLine(Icons.notes_rounded, '时间说明', timeNote),
          if (organizer.isNotEmpty)
            _draftLine(Icons.account_balance_outlined, '主办方', organizer),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              if (category.isNotEmpty) _draftChip('分类 $category'),
              if (recommendation.isNotEmpty) _draftChip('$recommendation 推荐'),
              _draftChip(recognition),
              _draftChip(source),
            ],
          ),
        ],
      ),
    );
  }

  Widget _draftLine(IconData icon, String label, String value) {
    final text = value.trim().isEmpty ? '未填写' : value.trim();
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          Icon(icon, size: 14, color: _competitionMuted),
          const SizedBox(width: 5),
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
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFF444150),
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _draftChip(String label) {
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

  DateTime? _draftSortDate(Map<String, dynamic> event) {
    return _parseDraftDate(_draftValue(event, 'registration_end')) ??
        _parseDraftDate(_draftValue(event, 'event_start'));
  }

  DateTime? _parseDraftDate(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return null;
    return DateTime.tryParse(value);
  }

  String _draftTimeText(
    Map<String, dynamic> event,
    String dateKey,
    String textKey,
  ) {
    final date = _draftValue(event, dateKey);
    if (date.isNotEmpty) return date;
    return _draftValue(event, textKey);
  }

  String _draftValue(Map<String, dynamic> event, String key) {
    return '${event[key] ?? ''}'.trim();
  }

  String _previewErrorText(dynamic error) {
    if (error is Map) {
      final index = error['index'];
      final field = error['field'];
      final message = error['message'];
      final prefix = index == null || '$index' == '-1' ? '全局' : '第 $index 条';
      return '$prefix：$field - $message';
    }
    return '$error';
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

String _calendarItemSourceLabel(String value) {
  switch (value) {
    case 'official':
      return '官方比赛';
    case 'share':
      return '分享导入';
    case 'manual':
      return '手动新增';
    default:
      return value.isEmpty ? '我的导入' : value;
  }
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
