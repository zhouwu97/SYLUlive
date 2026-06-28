import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/competition.dart';
import '../providers/auth_provider.dart';
import '../utils/app_feedback.dart';

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
    try {
      final results = await Future.wait([
        _dio.get('/competitions/categories'),
        _dio.get('/competitions/events', queryParameters: _queryParams()),
      ]);
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
      appBar: AppBar(
        title: const Text('竞赛中心'),
        actions: [
          if (user?.isAdmin == true)
            IconButton(
              onPressed: _openAdminImport,
              icon: const Icon(Icons.admin_panel_settings_outlined),
              tooltip: 'AI 辅助导入',
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            Text(
              '发现比赛，管理参赛计划',
              style: TextStyle(color: Theme.of(context).hintColor),
            ),
            const SizedBox(height: 14),
            SearchBar(
              controller: _searchController,
              hintText: '搜索比赛 / 主办方 / 标签',
              leading: const Icon(Icons.search),
              onSubmitted: (_) => _load(),
              trailing: [
                if (_searchController.text.isNotEmpty)
                  IconButton(
                    onPressed: () {
                      _searchController.clear();
                      _load();
                    },
                    icon: const Icon(Icons.close),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: _load,
                    icon: const Icon(Icons.workspace_premium_outlined),
                    label: const Text('官方比赛'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: _openCalendar,
                    icon: const Icon(Icons.event_available_outlined),
                    label: const Text('我的日历'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: _openShareImport,
                    icon: const Icon(Icons.ios_share_outlined),
                    label: const Text('导入分享'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _openFilters,
              icon: const Icon(Icons.tune),
              label: Text('筛选 / 分类   当前：$_filterSummary'),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Text('共 $_total 个比赛',
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                const Spacer(),
                Text('排序：即将截止',
                    style: TextStyle(color: Theme.of(context).hintColor)),
              ],
            ),
            const SizedBox(height: 8),
            if (_loading)
              const Padding(
                padding: EdgeInsets.only(top: 80),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_events.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 80),
                child: Center(child: Text('暂无比赛')),
              )
            else
              ..._events.map(_buildEventCard),
          ],
        ),
      ),
    );
  }

  Widget _buildEventCard(CompetitionEvent event) {
    return Card(
      margin: const EdgeInsets.only(top: 10),
      child: InkWell(
        onTap: () => _openDetail(event),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(event.title,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  _chip('${event.recommendationLevel}推荐'),
                  _chip(event.primaryCategory?.name ?? '未分类'),
                  _chip(_sourceLabel(event.sourceChannel)),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '学校认定：${_recognitionLabel(event.schoolRecognitionStatus)}'
                '${event.schoolRecognitionGrade.isNotEmpty ? ' ${event.schoolRecognitionGrade}' : ''}',
              ),
              if (_deadlineText(event).isNotEmpty)
                Text('报名截止：${_deadlineText(event)}'),
              if (event.eventTimeText.isNotEmpty)
                Text('比赛时间：${event.eventTimeText}'),
              const SizedBox(height: 10),
              Row(
                children: [
                  OutlinedButton(
                    onPressed: () => _openDetail(event),
                    child: const Text('详情'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: () => _copyToCalendar(event.id),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('加入'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _chip(String label) {
    return Chip(label: Text(label), visualDensity: VisualDensity.compact);
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
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CompetitionFilterScreen(
          categories: _categories,
          categorySlug: _categorySlug,
          recommendations: _recommendations,
          recognitions: _recognitions,
          sources: _sources,
          onApply: (category, recommendations, recognitions, sources) {
            setState(() {
              _categorySlug = category;
              _recommendations
                ..clear()
                ..addAll(recommendations);
              _recognitions
                ..clear()
                ..addAll(recognitions);
              _sources
                ..clear()
                ..addAll(sources);
            });
          },
        ),
      ),
    );
    _load();
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

class CompetitionFilterScreen extends StatefulWidget {
  final List<CompetitionCategory> categories;
  final String? categorySlug;
  final Set<String> recommendations;
  final Set<String> recognitions;
  final Set<String> sources;
  final void Function(
    String?,
    Set<String>,
    Set<String>,
    Set<String>,
  ) onApply;

  const CompetitionFilterScreen({
    super.key,
    required this.categories,
    required this.categorySlug,
    required this.recommendations,
    required this.recognitions,
    required this.sources,
    required this.onApply,
  });

  @override
  State<CompetitionFilterScreen> createState() =>
      _CompetitionFilterScreenState();
}

class _CompetitionFilterScreenState extends State<CompetitionFilterScreen> {
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('筛选比赛'),
        actions: [
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
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton(
            onPressed: () {
              widget.onApply(
                _categorySlug,
                _recommendations,
                _recognitions,
                _sources,
              );
              Navigator.pop(context);
            },
            child: const Text('查看结果'),
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('比赛领域',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
          RadioListTile<String?>(
            value: null,
            groupValue: _categorySlug,
            onChanged: (v) => setState(() => _categorySlug = v),
            title: const Text('全部'),
          ),
          ...widget.categories.map(
            (c) => RadioListTile<String?>(
              value: c.slug,
              groupValue: _categorySlug,
              onChanged: (v) => setState(() => _categorySlug = v),
              title: Text(c.name),
            ),
          ),
          _multi('推荐程度', {'S': 'S强烈推荐', 'A': 'A推荐', 'B': 'B可参加', 'C': 'C兴趣参加'},
              _recommendations),
          _multi(
              '学校认定',
              {
                'recognized': '已认定',
                'not_recognized': '未认定',
                'pending': '待确认',
                'unknown': '未知'
              },
              _recognitions),
          _multi(
              '来源类型',
              {
                'school_catalog': '学校目录',
                'enterprise': '企业赛事',
                'college_notice': '学院通知',
                'industry_association': '行业协会',
                'platform': '平台赛事',
                'admin_manual': '管理员精选',
                'ai_import': 'AI导入'
              },
              _sources),
        ],
      ),
    );
  }

  Widget _multi(String title, Map<String, String> options, Set<String> target) {
    return Padding(
      padding: const EdgeInsets.only(top: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style:
                  const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: options.entries
                .map((e) => FilterChip(
                      label: Text(e.value),
                      selected: target.contains(e.key),
                      onSelected: (selected) => setState(() {
                        selected ? target.add(e.key) : target.remove(e.key);
                      }),
                    ))
                .toList(),
          ),
        ],
      ),
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
      appBar: AppBar(title: const Text('我的比赛日历'), actions: [
        IconButton(onPressed: _share, icon: const Icon(Icons.ios_share)),
      ]),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text('已加入比赛 ${_items.length} 个',
                    style: const TextStyle(fontWeight: FontWeight.w800)),
                const SizedBox(height: 12),
                ..._items.map((raw) {
                  final item = Map<String, dynamic>.from(raw as Map);
                  return Card(
                    child: ListTile(
                      title: Text(item['title'] ?? ''),
                      subtitle: Text(
                        '${item['source_type'] ?? ''} · ${item['registration_time_text'] ?? ''}',
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () async {
                          await context.read<AuthProvider>().dio.delete(
                              '/user/competition-calendar/items/${item['id']}');
                          _load();
                        },
                      ),
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
