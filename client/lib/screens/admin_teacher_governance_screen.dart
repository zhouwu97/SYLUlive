import 'dart:async';
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:provider/provider.dart';

import '../models/teacher_governance.dart';
import '../providers/auth_provider.dart';
import '../theme/app_colors.dart';
import '../theme/app_radius.dart';
import '../theme/app_spacing.dart';
import '../theme/app_text_styles.dart';

class AdminTeacherGovernanceScreen extends StatefulWidget {
  const AdminTeacherGovernanceScreen({super.key});

  @override
  State<AdminTeacherGovernanceScreen> createState() =>
      _AdminTeacherGovernanceScreenState();
}

class _AdminTeacherGovernanceScreenState
    extends State<AdminTeacherGovernanceScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  // Tab 0: 疑似重复
  List<TeacherGovernanceCandidateGroup> _candidateGroups = [];
  bool _isLoadingGroups = false;
  String? _groupsError;

  // Tab 1: 全部教师
  List<TeacherGovernanceTeacherItem> _allTeachers = [];
  bool _isLoadingTeachers = false;
  String? _teachersError;
  String _teacherSearchQuery = '';
  bool _includeMerged = false;
  final Set<int> _selectedTeacherIds = {};
  Timer? _searchDebounce;

  // Tab 2: 别名管理
  String _aliasType = 'teacher'; // "teacher" | "course"
  List<GovernanceAliasItem> _aliases = [];
  bool _isLoadingAliases = false;
  String? _aliasesError;
  String _aliasSearchQuery = '';

  // Tab 3: 处理记录
  List<TeacherMergeRecordItem> _records = [];
  bool _isLoadingRecords = false;
  String? _recordsError;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _tabController.addListener(() {
      if (_tabController.indexIsChanging) return;
      _onTabChanged(_tabController.index);
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadCandidateGroups();
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    _searchDebounce?.cancel();
    super.dispose();
  }

  void _onTabChanged(int index) {
    switch (index) {
      case 0:
        if (_candidateGroups.isEmpty && !_isLoadingGroups) {
          _loadCandidateGroups();
        }
        break;
      case 1:
        if (_allTeachers.isEmpty && !_isLoadingTeachers) {
          _loadTeachers();
        }
        break;
      case 2:
        if (_aliases.isEmpty && !_isLoadingAliases) {
          _loadAliases();
        }
        break;
      case 3:
        if (_records.isEmpty && !_isLoadingRecords) {
          _loadRecords();
        }
        break;
    }
  }

  // ==========================================
  // 网络请求方法
  // ==========================================

  List<dynamic> _extractList(dynamic data, String primaryKey) {
    if (data is List) return data;
    if (data is Map) {
      final val = data[primaryKey] ?? data['items'] ?? data['data'] ?? data['list'];
      if (val is List) return val;
    }
    return const [];
  }

  Future<void> _loadCandidateGroups() async {
    if (!mounted) return;
    setState(() {
      _isLoadingGroups = true;
      _groupsError = null;
    });
    try {
      final dio = context.read<AuthProvider>().dio;
      final res =
          await dio.get('/api/admin/teacher-governance/duplicate-groups');
      if (!mounted) return;
      final items = _extractList(res.data, 'groups');
      setState(() {
        _candidateGroups = items
            .whereType<Map<String, dynamic>>()
            .map(TeacherGovernanceCandidateGroup.fromJson)
            .toList();
        _isLoadingGroups = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoadingGroups = false;
        _groupsError = '加载疑似重复分组失败: $e';
      });
    }
  }

  Future<void> _loadTeachers() async {
    if (!mounted) return;
    setState(() {
      _isLoadingTeachers = true;
      _teachersError = null;
    });
    try {
      final dio = context.read<AuthProvider>().dio;
      final params = <String, dynamic>{
        'include_merged': _includeMerged,
      };
      if (_teacherSearchQuery.trim().isNotEmpty) {
        params['q'] = _teacherSearchQuery.trim();
      }
      final res = await dio.get(
        '/api/admin/teacher-governance/teachers',
        queryParameters: params,
      );
      if (!mounted) return;
      final items = _extractList(res.data, 'teachers');
      setState(() {
        _allTeachers = items
            .whereType<Map<String, dynamic>>()
            .map(TeacherGovernanceTeacherItem.fromJson)
            .toList();
        _isLoadingTeachers = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoadingTeachers = false;
        _teachersError = '加载教师列表失败: $e';
      });
    }
  }

  Future<void> _loadAliases() async {
    if (!mounted) return;
    setState(() {
      _isLoadingAliases = true;
      _aliasesError = null;
    });
    try {
      final dio = context.read<AuthProvider>().dio;
      final params = <String, dynamic>{
        'type': _aliasType,
      };
      if (_aliasSearchQuery.trim().isNotEmpty) {
        params['q'] = _aliasSearchQuery.trim();
      }
      final res = await dio.get(
        '/api/admin/teacher-governance/aliases',
        queryParameters: params,
      );
      if (!mounted) return;
      final items = _extractList(res.data, 'aliases');
      setState(() {
        _aliases = items
            .whereType<Map<String, dynamic>>()
            .map((j) =>
                GovernanceAliasItem.fromJson(j, defaultType: _aliasType))
            .toList();
        _isLoadingAliases = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoadingAliases = false;
        _aliasesError = '加载别名列表失败: $e';
      });
    }
  }

  Future<void> _loadRecords() async {
    if (!mounted) return;
    setState(() {
      _isLoadingRecords = true;
      _recordsError = null;
    });
    try {
      final dio = context.read<AuthProvider>().dio;
      final res =
          await dio.get('/api/admin/teacher-governance/merge-records');
      if (!mounted) return;
      final items = _extractList(res.data, 'records');
      setState(() {
        _records = items
            .whereType<Map<String, dynamic>>()
            .map(TeacherMergeRecordItem.fromJson)
            .toList();
        _isLoadingRecords = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoadingRecords = false;
        _recordsError = '加载治理记录失败: $e';
      });
    }
  }

  // ==========================================
  // 别名增删
  // ==========================================

  Future<void> _showAddAliasDialog() async {
    final aliasCtrl = TextEditingController();
    final subjectCtrl = TextEditingController();
    final teacherCtrl = TextEditingController();
    int? selectedSubjectId;
    int? selectedTeacherId;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(_aliasType == 'teacher' ? '添加教师别名' : '添加课程别名'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_aliasType == 'teacher') ...[
                  TextField(
                    controller: subjectCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '标准学科 ID (必填)',
                      hintText: '所属课程学科 ID',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (val) {
                      selectedSubjectId = int.tryParse(val.trim());
                    },
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: teacherCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '目标教师 ID (必填)',
                      hintText: '指向的活动教师 ID',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (val) {
                      selectedTeacherId = int.tryParse(val.trim());
                    },
                  ),
                  const SizedBox(height: 12),
                ] else ...[
                  TextField(
                    controller: subjectCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '目标学科 ID (必填)',
                      hintText: '指向的标准学科 ID',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (val) {
                      selectedSubjectId = int.tryParse(val.trim());
                    },
                  ),
                  const SizedBox(height: 12),
                ],
                TextField(
                  controller: aliasCtrl,
                  decoration: InputDecoration(
                    labelText: '别名内容 (必填)',
                    hintText: _aliasType == 'teacher'
                        ? '如：张三老师'
                        : '如：高数上、高等数学A1',
                    border: const OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () async {
                final alias = aliasCtrl.text.trim();
                if (alias.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('请填写别名内容')),
                  );
                  return;
                }
                if (_aliasType == 'teacher') {
                  if (selectedSubjectId == null ||
                      selectedTeacherId == null) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('请填写学科ID与教师ID')),
                    );
                    return;
                  }
                } else {
                  if (selectedSubjectId == null) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('请填写目标学科ID')),
                    );
                    return;
                  }
                }

                Navigator.pop(ctx);
                try {
                  final dio = context.read<AuthProvider>().dio;
                  final payload = <String, dynamic>{
                    'type': _aliasType,
                    'alias': alias,
                    'course_subject_id': selectedSubjectId,
                  };
                  if (_aliasType == 'teacher') {
                    payload['teacher_id'] = selectedTeacherId;
                  }
                  await dio.post(
                    '/api/admin/teacher-governance/aliases',
                    data: payload,
                  );
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('别名添加成功'),
                        backgroundColor: Colors.green,
                      ),
                    );
                    _loadAliases();
                  }
                } on DioException catch (e) {
                  if (mounted) {
                    final err = e.response?.data is Map
                        ? e.response?.data['error']
                        : null;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(err?.toString() ?? '添加失败'),
                        backgroundColor: Colors.red,
                      ),
                    );
                  }
                } catch (_) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('添加失败'),
                        backgroundColor: Colors.red,
                      ),
                    );
                  }
                }
              },
              child: const Text('确认添加'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDeleteAlias(GovernanceAliasItem item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认删除别名'),
        content: Text('确定删除别名「${item.alias}」吗？\n删除后该名称将不再被自动解析至对应目标。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      final dio = context.read<AuthProvider>().dio;
      await dio.delete(
        '/api/admin/teacher-governance/aliases/${item.id}',
        queryParameters: {'type': item.type},
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('别名已删除'),
            backgroundColor: Colors.green,
          ),
        );
        setState(() => _aliases.removeWhere((a) => a.id == item.id));
      }
    } on DioException catch (e) {
      if (mounted) {
        final err = e.response?.data is Map ? e.response?.data['error'] : null;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(err?.toString() ?? '删除失败'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('删除失败'), backgroundColor: Colors.red),
        );
      }
    }
  }

  // ==========================================
  // 合并 BottomSheet
  // ==========================================

  void _openMergeSheet(
    BuildContext context,
    List<TeacherGovernanceTeacherItem> teachers, {
    int? initialKeeperId,
  }) {
    if (teachers.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('至少需要选择 2 位教师进行合并治理')),
      );
      return;
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _TeacherMergeBottomSheet(
        teachers: teachers,
        initialKeeperId: initialKeeperId,
        onSuccess: () {
          _loadCandidateGroups();
          _loadTeachers();
          _loadRecords();
          setState(() {
            _selectedTeacherIds.clear();
          });
        },
      ),
    );
  }

  // ==========================================
  // UI 渲染
  // ==========================================

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor:
            isDark ? AppColors.surfaceSecondaryDark : Colors.white,
        title: Text(
          '教师与课程数据治理',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w700,
            color: isDark ? Colors.white : AppColors.textPrimaryLight,
          ),
        ),
        bottom: TabBar(
          controller: _tabController,
          isScrollable: false,
          labelColor: AppColors.brandPrimary,
          unselectedLabelColor: isDark ? Colors.white60 : Colors.black54,
          indicatorColor: AppColors.brandPrimary,
          indicatorWeight: 3,
          tabs: [
            Tab(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text('疑似重复'),
                  if (_candidateGroups.isNotEmpty) ...[
                    const SizedBox(width: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: Colors.amber,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '${_candidateGroups.length}',
                        style: const TextStyle(
                          color: Colors.black,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const Tab(text: '全部教师'),
            const Tab(text: '别名管理'),
            const Tab(text: '处理记录'),
          ],
        ),
      ),
      body: SafeArea(
        top: false,
        child: TabBarView(
          controller: _tabController,
          children: [
            _buildDuplicateGroupsTab(isDark),
            _buildAllTeachersTab(isDark),
            _buildAliasesTab(isDark),
            _buildRecordsTab(isDark),
          ],
        ),
      ),
    );
  }

  // Tab 0: 疑似重复
  Widget _buildDuplicateGroupsTab(bool isDark) {
    if (_isLoadingGroups && _candidateGroups.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_groupsError != null && _candidateGroups.isEmpty) {
      return _buildErrorState(_groupsError!, _loadCandidateGroups, isDark);
    }
    if (_candidateGroups.isEmpty) {
      return _buildEmptyState(
        '暂无待处理的疑似重复教师',
        '系统目前未检测到同课程下高置信或疑似名称重复的教师条目。',
        _loadCandidateGroups,
        isDark,
      );
    }

    return RefreshIndicator(
      onRefresh: _loadCandidateGroups,
      child: ListView.builder(
        padding: const EdgeInsets.all(AppSpacing.md),
        itemCount: _candidateGroups.length,
        itemBuilder: (ctx, index) {
          final group = _candidateGroups[index];
          return _buildCandidateGroupCard(group, isDark);
        },
      ),
    );
  }

  Widget _buildCandidateGroupCard(
      TeacherGovernanceCandidateGroup group, bool isDark) {
    Color badgeBg;
    Color badgeText;
    switch (group.confidence) {
      case GovernanceConfidence.high:
        badgeBg = isDark ? const Color(0xFF064E3B) : const Color(0xFFD1FAE5);
        badgeText = isDark ? const Color(0xFF6EE7B7) : const Color(0xFF047857);
        break;
      case GovernanceConfidence.suspected:
        badgeBg = isDark ? const Color(0xFF78350F) : const Color(0xFFFEF3C7);
        badgeText = isDark ? const Color(0xFFFCD34D) : const Color(0xFFB45309);
        break;
      case GovernanceConfidence.hint:
        badgeBg = isDark ? const Color(0xFF1E3A8A) : const Color(0xFFDBEAFE);
        badgeText = isDark ? const Color(0xFF93C5FD) : const Color(0xFF1D4ED8);
        break;
    }

    return Card(
      margin: const EdgeInsets.only(bottom: AppSpacing.md),
      color: isDark ? AppColors.surfaceSecondaryDark : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        side: BorderSide(
          color: isDark ? Colors.white12 : AppColors.borderNormalLight,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header: 课程名 + 置信度 Badge
            Row(
              children: [
                Expanded(
                  child: Text(
                    group.courseName.isNotEmpty ? group.courseName : '未分类课程',
                    style: AppTextStyles.titleMedium.copyWith(
                      color: isDark ? Colors.white : AppColors.textPrimaryLight,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: badgeBg,
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                  child: Text(
                    group.confidence.label,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: badgeText,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            // 判断依据
            if (group.reasons.isNotEmpty) ...[
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: group.reasons.map((r) {
                  return Text(
                    '• $r',
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark ? Colors.white60 : Colors.black54,
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 10),
            ],
            const Divider(height: 1),
            const SizedBox(height: 10),
            // 教师候选列表
            ...group.teachers.map((t) {
              final isSuggested = t.id == group.suggestedKeeperId;
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 14,
                      backgroundColor: isSuggested
                          ? AppColors.brandPrimary
                          : Colors.grey.withValues(alpha: 0.3),
                      child: Text(
                        t.name.isNotEmpty ? t.name.substring(0, 1) : '?',
                        style: TextStyle(
                          fontSize: 12,
                          color: isSuggested ? Colors.white : (isDark ? Colors.white70 : Colors.black87),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      t.name,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight:
                            isSuggested ? FontWeight.bold : FontWeight.normal,
                        color:
                            isDark ? Colors.white : AppColors.textPrimaryLight,
                      ),
                    ),
                    const SizedBox(width: 6),
                    _buildSourceBadge(t.canonicalSource, isDark),
                    if (t.verified) ...[
                      const SizedBox(width: 4),
                      _buildVerifiedBadge(isDark),
                    ],
                    if (isSuggested) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: AppColors.brandPrimary.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text(
                          '建议保留',
                          style: TextStyle(
                            fontSize: 10,
                            color: AppColors.brandPrimary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                    const Spacer(),
                    Text(
                      '${t.ratingCount} 评价 · ${t.pendingCount} 待审',
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark ? Colors.white54 : Colors.black45,
                      ),
                    ),
                  ],
                ),
              );
            }),
            const SizedBox(height: 12),
            // 操作区域
            if (!group.mergeAllowed) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(AppSpacing.sm),
                decoration: BoxDecoration(
                  color: Colors.amber.withValues(alpha: isDark ? 0.15 : 0.1),
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.info_outline,
                        size: 16, color: Colors.amber),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        group.mergeBlockReason.isNotEmpty
                            ? group.mergeBlockReason
                            : '跨课程同名教师。当前 Teacher 是“课程下教师”实体，v1 不支持直接跨课程合并。',
                        style: TextStyle(
                          fontSize: 12,
                          color:
                              isDark ? Colors.amber[200] : Colors.amber[900],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ] else ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.brandPrimary,
                      padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.md, vertical: 8),
                    ),
                    onPressed: () {
                      _openMergeSheet(
                        context,
                        group.teachers,
                        initialKeeperId: group.suggestedKeeperId,
                      );
                    },
                    icon: const Icon(Icons.merge_type_rounded, size: 16),
                    label: const Text('处理合并'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  // Tab 1: 全部教师
  Widget _buildAllTeachersTab(bool isDark) {
    return Column(
      children: [
        // 搜索栏与过滤开关
        Padding(
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.md, AppSpacing.sm, AppSpacing.md, AppSpacing.xs),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  decoration: InputDecoration(
                    hintText: '搜索教师姓名或课程学科...',
                    prefixIcon: const Icon(Icons.search, size: 20),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                        vertical: 10, horizontal: 12),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppRadius.md),
                    ),
                  ),
                  onChanged: (val) {
                    _searchDebounce?.cancel();
                    _searchDebounce =
                        Timer(const Duration(milliseconds: 300), () {
                      setState(() {
                        _teacherSearchQuery = val;
                      });
                      _loadTeachers();
                    });
                  },
                ),
              ),
              const SizedBox(width: 8),
              FilterChip(
                label: Text(
                  _includeMerged ? '含已合并' : '仅活动',
                  style: const TextStyle(fontSize: 12),
                ),
                selected: _includeMerged,
                onSelected: (val) {
                  setState(() {
                    _includeMerged = val;
                  });
                  _loadTeachers();
                },
              ),
            ],
          ),
        ),
        // 教师列表
        Expanded(
          child: _isLoadingTeachers && _allTeachers.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : _teachersError != null && _allTeachers.isEmpty
                  ? _buildErrorState(_teachersError!, _loadTeachers, isDark)
                  : _allTeachers.isEmpty
                      ? _buildEmptyState(
                          '未找到符合条件的教师',
                          '可尝试修改搜索关键词或开启"含已合并"筛选。',
                          _loadTeachers,
                          isDark,
                        )
                      : RefreshIndicator(
                          onRefresh: _loadTeachers,
                          child: ListView.separated(
                            padding: const EdgeInsets.all(AppSpacing.md),
                            itemCount: _allTeachers.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 8),
                            itemBuilder: (ctx, index) {
                              final t = _allTeachers[index];
                              final isSelected =
                                  _selectedTeacherIds.contains(t.id);
                              return _buildTeacherListItem(
                                  t, isSelected, isDark);
                            },
                          ),
                        ),
        ),
        // 底部多选治理浮动栏
        if (_selectedTeacherIds.length >= 2) ...[
          Container(
            padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md, vertical: 12),
            decoration: BoxDecoration(
              color: isDark
                  ? AppColors.surfaceSecondaryDark
                  : Colors.white,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.1),
                  offset: const Offset(0, -2),
                  blurRadius: 8,
                ),
              ],
            ),
            child: Row(
              children: [
                Text(
                  '已选 ${_selectedTeacherIds.length} 位教师',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () {
                    setState(() {
                      _selectedTeacherIds.clear();
                    });
                  },
                  child: const Text('取消'),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.brandPrimary,
                  ),
                  onPressed: () {
                    final selectedTeachers = _allTeachers
                        .where((t) => _selectedTeacherIds.contains(t.id))
                        .toList();
                    _openMergeSheet(context, selectedTeachers);
                  },
                  icon: const Icon(Icons.merge_type_rounded, size: 16),
                  label: const Text('发起合并治理'),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildTeacherListItem(
      TeacherGovernanceTeacherItem t, bool isSelected, bool isDark) {
    return Card(
      margin: EdgeInsets.zero,
      color: isDark ? AppColors.surfaceSecondaryDark : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        side: BorderSide(
          color: isSelected
              ? AppColors.brandPrimary
              : (isDark ? Colors.white12 : AppColors.borderNormalLight),
          width: isSelected ? 1.5 : 1,
        ),
      ),
      child: ListTile(
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        leading: Checkbox(
          value: isSelected,
          activeColor: AppColors.brandPrimary,
          onChanged: t.isMerged
              ? null
              : (val) {
                  setState(() {
                    if (val == true) {
                      _selectedTeacherIds.add(t.id);
                    } else {
                      _selectedTeacherIds.remove(t.id);
                    }
                  });
                },
        ),
        title: Row(
          children: [
            Text(
              t.name,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                decoration: t.isMerged ? TextDecoration.lineThrough : null,
                color: isDark ? Colors.white : AppColors.textPrimaryLight,
              ),
            ),
            const SizedBox(width: 6),
            _buildSourceBadge(t.canonicalSource, isDark),
            if (t.verified) ...[
              const SizedBox(width: 4),
              _buildVerifiedBadge(isDark),
            ],
            if (t.isMerged) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  '已合并至 #${t.mergedIntoId}',
                  style: const TextStyle(fontSize: 10, color: Colors.red),
                ),
              ),
            ],
          ],
        ),
        subtitle: Text(
          '${t.subjectName.isNotEmpty ? t.subjectName : t.course} · ${t.ratingCount} 条评价 · ${t.pendingCount} 待审 · ID: #${t.id}',
          style: TextStyle(
            fontSize: 12,
            color: isDark ? Colors.white60 : Colors.black54,
          ),
        ),
      ),
    );
  }

  // Tab 2: 别名管理
  Widget _buildAliasesTab(bool isDark) {
    return Column(
      children: [
        // 分段切换与操作栏
        Padding(
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.md, AppSpacing.sm, AppSpacing.md, AppSpacing.xs),
          child: Row(
            children: [
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'teacher', label: Text('教师别名')),
                  ButtonSegment(value: 'course', label: Text('课程别名')),
                ],
                selected: {_aliasType},
                onSelectionChanged: (set) {
                  setState(() {
                    _aliasType = set.first;
                    _aliases.clear();
                  });
                  _loadAliases();
                },
              ),
              const Spacer(),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.brandPrimary,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                ),
                onPressed: _showAddAliasDialog,
                icon: const Icon(Icons.add, size: 16),
                label: const Text('添加别名'),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.md, AppSpacing.xs, AppSpacing.md, AppSpacing.xs),
          child: TextField(
            decoration: InputDecoration(
              hintText: '搜索别名或目标名称...',
              prefixIcon: const Icon(Icons.search, size: 20),
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
            ),
            onChanged: (val) {
              _searchDebounce?.cancel();
              _searchDebounce = Timer(const Duration(milliseconds: 300), () {
                setState(() {
                  _aliasSearchQuery = val;
                });
                _loadAliases();
              });
            },
          ),
        ),
        // 别名列表
        Expanded(
          child: _isLoadingAliases && _aliases.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : _aliasesError != null && _aliases.isEmpty
                  ? _buildErrorState(_aliasesError!, _loadAliases, isDark)
                  : _aliases.isEmpty
                      ? _buildEmptyState(
                          '暂无别名记录',
                          '添加别名后，模糊检索与提评提交将自动收敛至标准目标。',
                          _loadAliases,
                          isDark,
                        )
                      : RefreshIndicator(
                          onRefresh: _loadAliases,
                          child: ListView.separated(
                            padding: const EdgeInsets.all(AppSpacing.md),
                            itemCount: _aliases.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 8),
                            itemBuilder: (ctx, index) {
                              final item = _aliases[index];
                              return _buildAliasListItem(item, isDark);
                            },
                          ),
                        ),
        ),
      ],
    );
  }

  Widget _buildAliasListItem(GovernanceAliasItem item, bool isDark) {
    return Card(
      margin: EdgeInsets.zero,
      color: isDark ? AppColors.surfaceSecondaryDark : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        side: BorderSide(
          color: isDark ? Colors.white12 : AppColors.borderNormalLight,
        ),
      ),
      child: ListTile(
        title: Row(
          children: [
            Text(
              item.alias,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.arrow_forward_rounded,
                size: 14, color: Colors.grey),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '${item.targetName} (${item.type == 'teacher' ? '教师' : '学科'} #${item.targetId})',
                style: const TextStyle(
                  color: AppColors.brandPrimary,
                  fontWeight: FontWeight.w600,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        subtitle: Text(
          '来源: ${item.source} · 学科: ${item.subjectName.isNotEmpty ? item.subjectName : '#${item.subjectId}'}',
          style: TextStyle(
            fontSize: 12,
            color: isDark ? Colors.white60 : Colors.black54,
          ),
        ),
        trailing: IconButton(
          tooltip: '删除别名',
          icon: const Icon(Icons.delete_outline, color: Colors.red, size: 20),
          onPressed: () => _confirmDeleteAlias(item),
        ),
      ),
    );
  }

  // Tab 3: 处理记录
  Widget _buildRecordsTab(bool isDark) {
    if (_isLoadingRecords && _records.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_recordsError != null && _records.isEmpty) {
      return _buildErrorState(_recordsError!, _loadRecords, isDark);
    }
    if (_records.isEmpty) {
      return _buildEmptyState(
        '暂无治理记录',
        '完成教师合并或别名收敛后，审计记录将呈现在这里。',
        _loadRecords,
        isDark,
      );
    }

    // 按 batch_id 分组
    final batchMap = <String, List<TeacherMergeRecordItem>>{};
    for (final r in _records) {
      batchMap.putIfAbsent(r.batchId, () => []).add(r);
    }

    return RefreshIndicator(
      onRefresh: _loadRecords,
      child: ListView.builder(
        padding: const EdgeInsets.all(AppSpacing.md),
        itemCount: batchMap.keys.length,
        itemBuilder: (ctx, index) {
          final batchId = batchMap.keys.elementAt(index);
          final batchRecords = batchMap[batchId]!;
          final first = batchRecords.first;

          return Card(
            margin: const EdgeInsets.only(bottom: AppSpacing.md),
            color: isDark ? AppColors.surfaceSecondaryDark : Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.lg),
              side: BorderSide(
                color: isDark ? Colors.white12 : AppColors.borderNormalLight,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 批次头
                  Row(
                    children: [
                      const Icon(Icons.history_edu_rounded,
                          size: 18, color: AppColors.brandPrimary),
                      const SizedBox(width: 8),
                      Text(
                        first.createdAt != null
                            ? '${first.createdAt!.year}-${first.createdAt!.month.toString().padLeft(2, '0')}-${first.createdAt!.day.toString().padLeft(2, '0')} ${first.createdAt!.hour.toString().padLeft(2, '0')}:${first.createdAt!.minute.toString().padLeft(2, '0')}'
                            : '历史记录',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const Spacer(),
                      Text(
                        '管理员: ${first.adminName.isNotEmpty ? first.adminName : '#${first.adminId}'}',
                        style: TextStyle(
                          fontSize: 12,
                          color: isDark ? Colors.white60 : Colors.black54,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Divider(height: 1),
                  const SizedBox(height: 8),
                  // 合并条目
                  ...batchRecords.map((r) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          Text(
                            '${r.loserName} (${r.loserSubject})',
                            style: const TextStyle(
                              decoration: TextDecoration.lineThrough,
                              color: Colors.grey,
                            ),
                          ),
                          const SizedBox(width: 6),
                          const Icon(Icons.arrow_forward,
                              size: 12, color: Colors.grey),
                          const SizedBox(width: 6),
                          Text(
                            '${r.keeperName} (${r.keeperSubject})',
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              color: AppColors.brandPrimary,
                            ),
                          ),
                        ],
                      ),
                    );
                  }),
                  const SizedBox(height: 8),
                  // 统计数据
                  Wrap(
                    spacing: 12,
                    runSpacing: 4,
                    children: [
                      _buildRecordStatChip(
                          '评价迁移: ${batchRecords.fold<int>(0, (sum, r) => sum + r.migratedRatings)}'),
                      _buildRecordStatChip(
                          '冲突归档: ${batchRecords.fold<int>(0, (sum, r) => sum + r.softDeletedRatings)}'),
                      _buildRecordStatChip(
                          '投票重挂: ${batchRecords.fold<int>(0, (sum, r) => sum + r.migratedVotes)}'),
                      _buildRecordStatChip(
                          '提交归并: ${batchRecords.fold<int>(0, (sum, r) => sum + r.supersededSubmissions)}'),
                      _buildRecordStatChip(
                          '教师别名: ${batchRecords.fold<int>(0, (sum, r) => sum + r.teacherAliasesAdded)}'),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildRecordStatChip(String label) {
    return Text(
      label,
      style: const TextStyle(fontSize: 11, color: Colors.grey),
    );
  }

  // 通用状态组件
  Widget _buildEmptyState(
      String title, String subtitle, VoidCallback onRefresh, bool isDark) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: AppColors.brandPrimary.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.task_alt_rounded,
                color: AppColors.brandPrimary,
                size: 32,
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            Text(
              title,
              style: AppTextStyles.titleMedium.copyWith(
                color: isDark ? Colors.white : AppColors.textPrimaryLight,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: isDark ? Colors.white60 : Colors.black54,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            FilledButton.tonalIcon(
              onPressed: onRefresh,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('刷新'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorState(String error, VoidCallback onRetry, bool isDark) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Colors.red),
            const SizedBox(height: AppSpacing.md),
            Text(
              error,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: isDark ? Colors.white70 : Colors.black87,
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            FilledButton(
              onPressed: onRetry,
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSourceBadge(String source, bool isDark) {
    String label;
    Color color;
    switch (source) {
      case 'edu_schedule':
        label = '教务';
        color = Colors.blue;
        break;
      case 'admin':
        label = '管理员';
        color = Colors.purple;
        break;
      case 'user':
        label = '用户';
        color = Colors.orange;
        break;
      case 'legacy':
      default:
        label = '历史';
        color = Colors.grey;
        break;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: isDark ? 0.2 : 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _buildVerifiedBadge(bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: Colors.green.withValues(alpha: isDark ? 0.2 : 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: const Text(
        '已核验',
        style: TextStyle(
          fontSize: 10,
          color: Colors.green,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

// ============================================================================
// 合并 BottomSheet 组件
// ============================================================================

class _TeacherMergeBottomSheet extends StatefulWidget {
  final List<TeacherGovernanceTeacherItem> teachers;
  final int? initialKeeperId;
  final VoidCallback onSuccess;

  const _TeacherMergeBottomSheet({
    required this.teachers,
    this.initialKeeperId,
    required this.onSuccess,
  });

  @override
  State<_TeacherMergeBottomSheet> createState() =>
      _TeacherMergeBottomSheetState();
}

class _TeacherMergeBottomSheetState extends State<_TeacherMergeBottomSheet> {
  late int _keeperId;
  bool _registerAliases = true;
  bool _mergeSubjectEntity = false;

  bool _isLoadingPreview = false;
  String? _previewError;
  GovernanceMergePreviewResult? _preview;

  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    _keeperId = widget.initialKeeperId != null &&
            widget.teachers.any((t) => t.id == widget.initialKeeperId)
        ? widget.initialKeeperId!
        : widget.teachers.first.id;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _fetchPreview();
    });
  }

  List<int> get _loserIds {
    return widget.teachers
        .where((t) => t.id != _keeperId)
        .map((t) => t.id)
        .toList();
  }

  Future<void> _fetchPreview() async {
    if (!mounted) return;
    setState(() {
      _isLoadingPreview = true;
      _previewError = null;
    });

    try {
      final dio = context.read<AuthProvider>().dio;
      final payload = {
        'keeper_id': _keeperId,
        'loser_ids': _loserIds,
        'register_aliases': _registerAliases,
        'course_merges': _mergeSubjectEntity
            ? [
                {
                  'merge_subject_entity': true,
                  'register_course_alias': true,
                }
              ]
            : [],
      };

      final res = await dio.post(
        '/api/admin/teacher-governance/merge-preview',
        data: payload,
      );
      if (!mounted) return;
      final data = res.data;
      if (data is Map) {
        setState(() {
          _preview = GovernanceMergePreviewResult.fromJson(
            Map<String, dynamic>.from(data),
          );
          _isLoadingPreview = false;
        });
      } else {
        setState(() {
          _previewError = '预览响应格式异常';
          _isLoadingPreview = false;
        });
      }
    } on DioException catch (e) {
      if (!mounted) return;
      final err = e.response?.data is Map ? e.response?.data['error'] : null;
      setState(() {
        _isLoadingPreview = false;
        _previewError = err?.toString() ?? '预览失败: $e';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoadingPreview = false;
        _previewError = '预览异常: $e';
      });
    }
  }

  Future<void> _submitMerge() async {
    if (_preview == null || !_preview!.mergeAllowed) return;
    setState(() {
      _isSubmitting = true;
    });

    try {
      final dio = context.read<AuthProvider>().dio;
      final payload = {
        'keeper_id': _keeperId,
        'loser_ids': _loserIds,
        'snapshot_token': _preview!.snapshotToken,
        'register_aliases': _registerAliases,
        'course_merges': _mergeSubjectEntity
            ? [
                {
                  'merge_subject_entity': true,
                  'register_course_alias': true,
                }
              ]
            : [],
      };

      final res = await dio.post(
        '/api/admin/teacher-governance/merge',
        data: payload,
      );
      if (!mounted) return;
      final msg = res.data is Map && res.data['message'] != null
          ? res.data['message'].toString()
          : '合并成功';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), backgroundColor: Colors.green),
      );
      Navigator.pop(context);
      widget.onSuccess();
    } on DioException catch (e) {
      if (!mounted) return;
      final data = e.response?.data;
      final code = data is Map ? data['code']?.toString() : null;
      final err = data is Map ? data['error']?.toString() : null;

      if (code == 'GOVERNANCE_SNAPSHOT_STALE') {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('数据已被其他人修改，已自动刷新预览快照'),
            backgroundColor: Colors.orange,
          ),
        );
        _fetchPreview();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(err ?? '合并失败'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('合并失败: $e'), backgroundColor: Colors.red),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.85,
      ),
      decoration: BoxDecoration(
        color: isDark ? AppColors.surfaceSecondaryDark : Colors.white,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppRadius.sheet),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 顶部拖拽把手
          Container(
            margin: const EdgeInsets.only(top: 10, bottom: 6),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.grey.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          // 标题栏
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: Row(
              children: [
                const Icon(Icons.merge_type_rounded,
                    color: AppColors.brandPrimary),
                const SizedBox(width: 8),
                Text(
                  '合并教师治理',
                  style: AppTextStyles.titleMedium.copyWith(
                    fontWeight: FontWeight.bold,
                    color: isDark ? Colors.white : AppColors.textPrimaryLight,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          // 滚轮内容
          Expanded(
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                  AppSpacing.md, AppSpacing.sm, AppSpacing.md, bottomInset + 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 第一部分：选择 Canonical Teacher (保留谁)
                  Text(
                    '第一步：选择保留的主教师实体 (Keeper)',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: isDark ? Colors.white70 : Colors.black87,
                    ),
                  ),
                  const SizedBox(height: 6),
                  RadioGroup<int>(
                    groupValue: _keeperId,
                    onChanged: (val) {
                      if (val != null && val != _keeperId) {
                        setState(() {
                          _keeperId = val;
                        });
                        _fetchPreview();
                      }
                    },
                    child: Column(
                      children: widget.teachers.map((t) {
                        final isSelected = t.id == _keeperId;
                        return RadioListTile<int>(
                          contentPadding: EdgeInsets.zero,
                          value: t.id,
                          activeColor: AppColors.brandPrimary,
                          title: Text(
                            '${t.name} · #${t.id} (${t.subjectName.isNotEmpty ? t.subjectName : t.course})',
                            style: TextStyle(
                              fontWeight: isSelected
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                            ),
                          ),
                          subtitle: Text(
                            '${t.ratingCount} 条评价 · 来源: ${t.canonicalSource}',
                            style: const TextStyle(fontSize: 12),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Divider(height: 1),
                  const SizedBox(height: 12),

                  // 第二部分：影响预览
                  Text(
                    '第二步：实体影响预览',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: isDark ? Colors.white70 : Colors.black87,
                    ),
                  ),
                  const SizedBox(height: 8),

                  if (_isLoadingPreview) ...[
                    const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24.0),
                        child: CircularProgressIndicator(),
                      ),
                    ),
                  ] else if (_previewError != null) ...[
                    Container(
                      padding: const EdgeInsets.all(AppSpacing.md),
                      decoration: BoxDecoration(
                        color: Colors.red.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(AppRadius.md),
                      ),
                      child: Text(
                        _previewError!,
                        style: const TextStyle(color: Colors.red),
                      ),
                    ),
                  ] else if (_preview != null) ...[
                    _buildPreviewImpactCard(_preview!, isDark),
                  ],

                  const SizedBox(height: 16),
                  // 第三部分：别名与课程配置
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    activeTrackColor: AppColors.brandPrimary,
                    title: const Text('登记被合并教师名称为别名'),
                    subtitle: const Text('后续输入被合并教师姓名时，将自动匹配至保留教师'),
                    value: _registerAliases,
                    onChanged: (val) {
                      setState(() {
                        _registerAliases = val;
                      });
                      _fetchPreview();
                    },
                  ),
                  if (widget.teachers.map((t) => t.subjectId).toSet().length > 1) ...[
                    const SizedBox(height: 8),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      activeTrackColor: AppColors.brandPrimary,
                      title: const Text('归并课程学科实体'),
                      subtitle: const Text('所选教师分属不同课程，开启此项将在合并教师的同时将课程归并至保留教师课程'),
                      value: _mergeSubjectEntity,
                      onChanged: (val) {
                        setState(() {
                          _mergeSubjectEntity = val;
                        });
                        _fetchPreview();
                      },
                    ),
                  ],
                ],
              ),
            ),
          ),
          // 底部操作栏
          Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: SizedBox(
              width: double.infinity,
              height: 48,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.brandPrimary,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                ),
                onPressed: (_isLoadingPreview ||
                        _isSubmitting ||
                        _preview == null ||
                        !_preview!.mergeAllowed)
                    ? null
                    : _submitMerge,
                child: _isSubmitting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text(
                        '确认原子合并',
                        style: TextStyle(
                            fontSize: 15, fontWeight: FontWeight.bold),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPreviewImpactCard(
      GovernanceMergePreviewResult preview, bool isDark) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 统计网格
        Container(
          padding: const EdgeInsets.all(AppSpacing.md),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1B232D) : const Color(0xFFF1F5F9),
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: _buildMetricItem(
                      '教师实体',
                      '${1 + preview.loserIds.length} → 1',
                      isDark,
                    ),
                  ),
                  Expanded(
                    child: _buildMetricItem(
                      '评价迁移',
                      '${preview.ratingsMigrated} 条',
                      isDark,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: _buildMetricItem(
                      '重复归档',
                      '${preview.ratingsSoftDeleted} 条',
                      isDark,
                      color: preview.ratingsSoftDeleted > 0
                          ? Colors.orange
                          : null,
                    ),
                  ),
                  Expanded(
                    child: _buildMetricItem(
                      '投票重挂',
                      '${preview.votesMigrated} 票',
                      isDark,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: _buildMetricItem(
                      '提交归并',
                      '${preview.submissionsSuperseded} 条',
                      isDark,
                    ),
                  ),
                  Expanded(
                    child: _buildMetricItem(
                      '状态标记',
                      'loser 保留 tombstone',
                      isDark,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        // 重复评价冲突警示
        if (preview.ratingConflicts.isNotEmpty) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color: Colors.amber.withValues(alpha: isDark ? 0.2 : 0.1),
              borderRadius: BorderRadius.circular(AppRadius.md),
              border: Border.all(
                color: isDark ? Colors.amber[700]! : Colors.amber[300]!,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.warning_amber_rounded,
                        color: Colors.amber, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '发现 ${preview.ratingConflicts.length} 名用户同时评价过合并目标与候选：',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color:
                              isDark ? Colors.amber[200] : Colors.amber[900],
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                const Text(
                  '系统将依据规则自动保留最新一条评价，其余评价转入归档，避免违反单用户唯一评价约束。',
                  style: TextStyle(fontSize: 12, height: 1.4),
                ),
              ],
            ),
          ),
        ],
        // 阻塞冲突
        if (!preview.mergeAllowed && preview.blockReason.isNotEmpty) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color: Colors.red.withValues(alpha: isDark ? 0.2 : 0.1),
              borderRadius: BorderRadius.circular(AppRadius.md),
              border: Border.all(color: Colors.red),
            ),
            child: Row(
              children: [
                const Icon(Icons.block_rounded, color: Colors.red, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    preview.blockReason,
                    style: const TextStyle(
                      color: Colors.red,
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildMetricItem(String label, String value, bool isDark,
      {Color? color}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: isDark ? Colors.white54 : Colors.black54,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.bold,
            color: color ?? (isDark ? Colors.white : Colors.black87),
          ),
        ),
      ],
    );
  }
}
