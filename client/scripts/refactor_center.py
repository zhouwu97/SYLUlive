import re

with open('e:/AI/xynewui/client/lib/screens/competition/competition_center_screen.dart', 'r', encoding='utf-8') as f:
    content = f.read()

# 1. Add new state fields
state_vars = """  String? _categorySlug;
  final Set<String> _recommendations = {};
  final Set<String> _recognitions = {};
  final Set<String> _sources = {};
  int? _calendarCount;"""

new_state_vars = """  String? _categorySlug;
  final Set<String> _recommendations = {};
  final Set<String> _recognitions = {};
  final Set<String> _sources = {};
  int? _calendarCount;
  
  String _adminStatusFilter = 'all'; // all, draft, active
  int _adminTotalCount = 0;
  int _adminDraftCount = 0;
  int _adminActiveCount = 0;"""

content = content.replace(state_vars, new_state_vars)

# 2. Refactor _load() to fetch admin stats and pass correct status filter
load_method = """  Future<void> _load() async {
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
  }"""

new_load_method = """  Future<void> _load() async {
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
  }"""

content = content.replace(load_method, new_load_method)

# 3. Refactor build() to inject the title, admin chips, and make it scrollable correctly
build_method_old = """  @override
  Widget build(BuildContext context) {
    final user = context.watch<AuthProvider>().user;
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
          if (user?.isAdmin == true)
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
      body: Column(
        children: [
          CompetitionCenterHeader(
            myPlanCount: _calendarCount ?? 0,
            pendingTimeCount: _events.where((event) => event.registrationEnd == null).length,
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
            isAdmin: user?.isAdmin == true,
          ),
          Expanded(
            child: _loading
                ? const Center(
                    child: CircularProgressIndicator(
                      color: _competitionPrimary,
                    ),
                  )
                : _events.isEmpty
                    ? SingleChildScrollView(
                        child: CompetitionEmptyState(
                          title: user?.isAdmin == true
                              ? '官方比赛库还没有内容'
                              : '暂时没有官方推荐比赛',
                          message: user?.isAdmin == true
                              ? '官方比赛库还没有内容。建议先导入一批长期稳定比赛，再逐步补充今年通知。'
                              : '暂时没有官方推荐比赛。你可以先导入同学整理的计划，或手动添加想关注的比赛。',
                          primaryText: user?.isAdmin == true ? 'AI导入' : '导入计划',
                          onPrimaryTap: user?.isAdmin == true
                              ? _openAdminImport
                              : _openShareImport,
                          secondaryText: user?.isAdmin == true ? '新建比赛' : '刷新',
                          onSecondaryTap: user?.isAdmin == true ? _openAdminManualCreate : _load,
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
  }"""

build_method_new = """  @override
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
                  children: _events.map((e) => Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _buildEventCard(e),
                  )).toList(),
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
  }"""

content = content.replace(build_method_old, build_method_new)

with open('e:/AI/xynewui/client/lib/screens/competition/competition_center_screen.dart', 'w', encoding='utf-8') as f:
    f.write(content)
print("Updated competition_center_screen.dart")
