import 'dart:async';
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:provider/provider.dart';

import '../models/teacher_governance.dart';
import '../providers/auth_provider.dart';
import '../providers/course_subject_provider.dart';
import '../providers/teacher_provider.dart';
import '../theme/app_colors.dart';
import '../theme/app_radius.dart';
import '../theme/app_spacing.dart';
import '../theme/app_text_styles.dart';

class AdminTeacherGovernanceScreen extends StatefulWidget {
  final int initialTab;
  final int? initialSubjectId;
  final String? initialSubjectName;
  final int? initialTeacherId;
  final String? initialTeacherName;

  const AdminTeacherGovernanceScreen({
    super.key,
    this.initialTab = 0,
    this.initialSubjectId,
    this.initialSubjectName,
    this.initialTeacherId,
    this.initialTeacherName,
  });

  @override
  State<AdminTeacherGovernanceScreen> createState() =>
      _AdminTeacherGovernanceScreenState();
}

class _AdminTeacherGovernanceScreenState
    extends State<AdminTeacherGovernanceScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  bool _hasChanged = false;

  // ==========================================
  // Tab 0: 课程合并 (3步式独立工作流)
  // ==========================================
  int _courseMergeStep = 0; // 0: 选择对象, 1: 确认名称与教师对应, 2: 预览并执行
  GovernanceCourseItem? _sourceCourse; // 被合并课程 (loser)
  GovernanceCourseItem? _targetCourse; // 目标保留课程 (keeper)
  final TextEditingController _finalCourseNameCtrl = TextEditingController();
  final TextEditingController _courseMergeReasonCtrl =
      TextEditingController(text: '学科与课程名称规范化合并');
  final bool _registerCourseAlias = true;

  List<TeacherGovernanceTeacherItem> _sourceCourseTeachers = [];
  List<TeacherGovernanceTeacherItem> _targetCourseTeachers = [];
  bool _isLoadingCourseTeachers = false;
  String? _courseTeachersError;

  // 教师对应关系: sourceTeacherId -> targetTeacherId? (null 表示独立保留为新教师)
  final Map<int, int?> _courseTeacherPairings = {};
  // 合并后的教师名称: sourceTeacherId -> finalTeacherName
  final Map<int, String> _courseTeacherFinalNames = {};

  CourseMergePreviewResult? _coursePreview;
  bool _isLoadingCoursePreview = false;
  String? _coursePreviewError;
  bool _isExecutingCourseMerge = false;

  // ==========================================
  // Tab 1: 教师合并 (全部教师与跨搜索多选合并)
  // ==========================================
  // 服务端治理能力检测
  // ==========================================
  bool _isCheckingCapability = true;
  bool _serverUnsupported = false;

  // ==========================================
  // Tab 1: 教师合并 (全部教师与跨搜索多选合并)
  // ==========================================
  List<TeacherGovernanceTeacherItem> _allTeachers = [];
  bool _isLoadingTeachers = false;
  bool _isLoadingMoreTeachers = false;
  bool _hasMoreTeachers = true;
  int? _teacherNextCursor;
  String? _teachersError;
  String _teacherSearchQuery = '';
  bool _includeMerged = false;
  // 修复跨搜索漏选 Bug: 用独立 Map 存储已选对象，不受搜索切换影响
  final Map<int, TeacherGovernanceTeacherItem> _selectedTeachers = {};
  Timer? _teacherSearchDebounce;
  int _teacherSearchGen = 0;
  CancelToken? _teacherCancelToken;
  final ScrollController _teacherScrollController = ScrollController();

  // ==========================================
  // Tab 2: 处理记录
  // ==========================================
  List<TeacherMergeRecordItem> _records = [];
  bool _isLoadingRecords = false;
  bool _isLoadingMoreRecords = false;
  bool _hasMoreRecords = true;
  int? _recordsNextCursor;
  String? _recordsError;
  final ScrollController _recordsScrollController = ScrollController();

  // ==========================================
  // Tab 3: 别名管理
  // ==========================================
  String _aliasType = 'teacher'; // "teacher" | "course"
  List<GovernanceAliasItem> _aliases = [];
  bool _isLoadingAliases = false;
  bool _isLoadingMoreAliases = false;
  bool _hasMoreAliases = true;
  int _aliasPage = 1;
  String? _aliasesError;
  String _aliasSearchQuery = '';
  Timer? _aliasSearchDebounce;
  int _aliasSearchGen = 0;
  CancelToken? _aliasCancelToken;
  final ScrollController _aliasesScrollController = ScrollController();

  // ==========================================
  // Tab 4: 疑似推荐
  // ==========================================
  List<TeacherGovernanceCandidateGroup> _candidateGroups = [];
  bool _isLoadingGroups = false;
  String? _groupsError;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 5,
      initialIndex: widget.initialTab.clamp(0, 4),
      vsync: this,
    );
    _tabController.addListener(() {
      if (_tabController.indexIsChanging) return;
      _onTabChanged(_tabController.index);
    });

    _teacherScrollController.addListener(() {
      if (_teacherScrollController.position.pixels >=
          _teacherScrollController.position.maxScrollExtent - 200) {
        if (_hasMoreTeachers && !_isLoadingMoreTeachers && !_isLoadingTeachers) {
          _loadTeachers(loadMore: true);
        }
      }
    });

    _recordsScrollController.addListener(() {
      if (_recordsScrollController.position.pixels >=
          _recordsScrollController.position.maxScrollExtent - 200) {
        if (_hasMoreRecords && !_isLoadingMoreRecords && !_isLoadingRecords) {
          _loadRecords(loadMore: true);
        }
      }
    });

    _aliasesScrollController.addListener(() {
      if (_aliasesScrollController.position.pixels >=
          _aliasesScrollController.position.maxScrollExtent - 200) {
        if (_hasMoreAliases && !_isLoadingMoreAliases && !_isLoadingAliases) {
          _loadAliases(loadMore: true);
        }
      }
    });

    if (widget.initialSubjectId != null) {
      _sourceCourse = GovernanceCourseItem(
        id: widget.initialSubjectId!,
        name: widget.initialSubjectName ?? '课程 #${widget.initialSubjectId}',
        teacherCount: 0,
        ratingCount: 0,
        isMerged: false,
      );
    }

    if (widget.initialTeacherName != null &&
        widget.initialTeacherName!.isNotEmpty) {
      _teacherSearchQuery = widget.initialTeacherName!;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkServerCapabilities();
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    _teacherScrollController.dispose();
    _recordsScrollController.dispose();
    _aliasesScrollController.dispose();
    _teacherSearchDebounce?.cancel();
    _aliasSearchDebounce?.cancel();
    _teacherCancelToken?.cancel();
    _aliasCancelToken?.cancel();
    _finalCourseNameCtrl.dispose();
    _courseMergeReasonCtrl.dispose();
    super.dispose();
  }

  Future<void> _checkServerCapabilities() async {
    setState(() {
      _isCheckingCapability = true;
      _serverUnsupported = false;
    });
    try {
      final dio = context.read<AuthProvider>().dio;
      Response? res;
      try {
        res = await dio.get('/version');
      } catch (_) {
        try {
          res = await dio.get('/version');
        } catch (_) {
          try {
            res = await dio.get('/health');
          } catch (_) {}
        }
      }
      if (!mounted) return;
      if (res == null || res.data == null) {
        setState(() {
          _isCheckingCapability = false;
          _serverUnsupported = true;
        });
        return;
      }
      final caps = ServerCapabilities.fromJson(
        res.data is Map<String, dynamic> ? res.data : {},
      );
      if (!caps.teacherGovernanceV1) {
        setState(() {
          _isCheckingCapability = false;
          _serverUnsupported = true;
        });
        return;
      }
      setState(() {
        _isCheckingCapability = false;
        _serverUnsupported = false;
      });
      _onTabChanged(_tabController.index);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isCheckingCapability = false;
        _serverUnsupported = true;
      });
    }
  }

  void _onTabChanged(int index) {
    if (_serverUnsupported) return;
    switch (index) {
      case 0:
        // Course merge
        break;
      case 1:
        if (_allTeachers.isEmpty && !_isLoadingTeachers) {
          _loadTeachers();
        }
        break;
      case 2:
        if (_records.isEmpty && !_isLoadingRecords) {
          _loadRecords();
        }
        break;
      case 3:
        if (_aliases.isEmpty && !_isLoadingAliases) {
          _loadAliases();
        }
        break;
      case 4:
        if (_candidateGroups.isEmpty && !_isLoadingGroups) {
          _loadCandidateGroups();
        }
        break;
    }
  }

  // ==========================================
  // 网络数据解析与请求
  // ==========================================

  List<dynamic> _extractList(dynamic data, String primaryKey) {
    if (data is List) return data;
    if (data is Map) {
      final val =
          data[primaryKey] ?? data['items'] ?? data['data'] ?? data['list'];
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
          await dio.get('/admin/teacher-governance/duplicate-groups');
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
        _groupsError = GovernanceApiErrorMapper.format(e, fallback: '加载疑似重复分组失败');
      });
    }
  }

  Future<void> _loadTeachers({bool loadMore = false}) async {
    if (!mounted) return;
    if (loadMore) {
      if (!_hasMoreTeachers || _isLoadingMoreTeachers || _isLoadingTeachers) {
        return;
      }
      setState(() => _isLoadingMoreTeachers = true);
    } else {
      _teacherCancelToken?.cancel();
      _teacherCancelToken = CancelToken();
      ++_teacherSearchGen;
      setState(() {
        _isLoadingTeachers = true;
        _isLoadingMoreTeachers = false;
        _teachersError = null;
        _teacherNextCursor = null;
        _hasMoreTeachers = true;
      });
    }

    final cancelToken = _teacherCancelToken;
    final currentGen = _teacherSearchGen;

    try {
      final dio = context.read<AuthProvider>().dio;
      final params = <String, dynamic>{
        'include_merged': _includeMerged,
        'limit': 50,
      };
      if (_teacherSearchQuery.trim().isNotEmpty) {
        params['q'] = _teacherSearchQuery.trim();
      }
      if (loadMore && _teacherNextCursor != null) {
        params['cursor'] = _teacherNextCursor;
      }
      final res = await dio.get(
        '/admin/teacher-governance/teachers',
        queryParameters: params,
        cancelToken: cancelToken,
      );
      if (!mounted || currentGen != _teacherSearchGen) return;

      final items = _extractList(res.data, 'teachers');
      final newItems = items
          .whereType<Map<String, dynamic>>()
          .map(TeacherGovernanceTeacherItem.fromJson)
          .toList();

      final bool hasMore = res.data is Map && res.data['has_more'] == true;
      final int? nextCursor =
          res.data is Map ? (res.data['next_cursor'] as num?)?.toInt() : null;

      setState(() {
        if (loadMore) {
          _allTeachers.addAll(newItems);
          _isLoadingMoreTeachers = false;
        } else {
          _allTeachers = newItems;
          _isLoadingTeachers = false;
        }
        _hasMoreTeachers = hasMore;
        _teacherNextCursor =
            nextCursor ?? (newItems.isNotEmpty ? newItems.last.id : null);

        // 如果通过 initialTeacherId 打开且尚未选中，自动加入选中集合
        if (widget.initialTeacherId != null) {
          for (final t in _allTeachers) {
            if (t.id == widget.initialTeacherId) {
              _selectedTeachers[t.id] = t;
            }
          }
        }
      });
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) {
        if (mounted && loadMore) {
          setState(() => _isLoadingMoreTeachers = false);
        }
        return;
      }
      if (!mounted || currentGen != _teacherSearchGen) return;
      setState(() {
        if (loadMore) {
          _isLoadingMoreTeachers = false;
        } else {
          _isLoadingTeachers = false;
        }
        _teachersError = GovernanceApiErrorMapper.format(e, fallback: '加载教师列表失败');
      });
    } catch (e) {
      if (!mounted || currentGen != _teacherSearchGen) return;
      setState(() {
        if (loadMore) {
          _isLoadingMoreTeachers = false;
        } else {
          _isLoadingTeachers = false;
        }
        _teachersError = GovernanceApiErrorMapper.format(e, fallback: '加载教师列表失败');
      });
    }
  }

  Future<void> _loadAliases({bool loadMore = false}) async {
    if (!mounted) return;
    if (loadMore) {
      if (!_hasMoreAliases || _isLoadingMoreAliases || _isLoadingAliases) {
        return;
      }
      setState(() => _isLoadingMoreAliases = true);
    } else {
      _aliasCancelToken?.cancel();
      _aliasCancelToken = CancelToken();
      ++_aliasSearchGen;
      setState(() {
        _isLoadingAliases = true;
        _isLoadingMoreAliases = false;
        _aliasesError = null;
        _aliasPage = 1;
        _hasMoreAliases = true;
      });
    }

    final cancelToken = _aliasCancelToken;
    final currentGen = _aliasSearchGen;
    final targetPage = loadMore ? _aliasPage + 1 : 1;

    try {
      final dio = context.read<AuthProvider>().dio;
      final params = <String, dynamic>{
        'type': _aliasType,
        'page': targetPage,
        'limit': 50,
      };
      if (_aliasSearchQuery.trim().isNotEmpty) {
        params['q'] = _aliasSearchQuery.trim();
      }
      final res = await dio.get(
        '/admin/teacher-governance/aliases',
        queryParameters: params,
        cancelToken: cancelToken,
      );
      if (!mounted || currentGen != _aliasSearchGen) return;
      final items = _extractList(res.data, 'aliases');
      final newItems = items
          .whereType<Map<String, dynamic>>()
          .map((j) =>
              GovernanceAliasItem.fromJson(j, defaultType: _aliasType))
          .toList();

      final bool hasMore = res.data is Map && res.data['has_more'] == true;

      setState(() {
        if (loadMore) {
          _aliases.addAll(newItems);
          _aliasPage = targetPage;
          _isLoadingMoreAliases = false;
        } else {
          _aliases = newItems;
          _aliasPage = 1;
          _isLoadingAliases = false;
        }
        _hasMoreAliases = hasMore;
      });
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) {
        if (mounted && loadMore) {
          setState(() => _isLoadingMoreAliases = false);
        }
        return;
      }
      if (!mounted || currentGen != _aliasSearchGen) return;
      setState(() {
        if (loadMore) {
          _isLoadingMoreAliases = false;
        } else {
          _isLoadingAliases = false;
        }
        _aliasesError = GovernanceApiErrorMapper.format(e, fallback: '加载别名列表失败');
      });
    } catch (e) {
      if (!mounted || currentGen != _aliasSearchGen) return;
      setState(() {
        if (loadMore) {
          _isLoadingMoreAliases = false;
        } else {
          _isLoadingAliases = false;
        }
        _aliasesError = GovernanceApiErrorMapper.format(e, fallback: '加载别名列表失败');
      });
    }
  }

  Future<void> _loadRecords({bool loadMore = false}) async {
    if (!mounted) return;
    if (loadMore) {
      if (!_hasMoreRecords || _isLoadingMoreRecords || _isLoadingRecords) {
        return;
      }
      setState(() => _isLoadingMoreRecords = true);
    } else {
      setState(() {
        _isLoadingRecords = true;
        _isLoadingMoreRecords = false;
        _recordsError = null;
        _recordsNextCursor = null;
        _hasMoreRecords = true;
      });
    }

    try {
      final dio = context.read<AuthProvider>().dio;
      final params = <String, dynamic>{
        'limit': 50,
      };
      if (loadMore && _recordsNextCursor != null) {
        params['cursor'] = _recordsNextCursor;
      }
      final res = await dio.get(
        '/admin/teacher-governance/merge-records',
        queryParameters: params,
      );
      if (!mounted) return;
      final items = _extractList(res.data, 'records');
      final newItems = items
          .whereType<Map<String, dynamic>>()
          .map(TeacherMergeRecordItem.fromJson)
          .toList();

      final bool hasMore = res.data is Map && res.data['has_more'] == true;
      final int? nextCursor =
          res.data is Map ? (res.data['next_cursor'] as num?)?.toInt() : null;

      setState(() {
        if (loadMore) {
          _records.addAll(newItems);
          _isLoadingMoreRecords = false;
        } else {
          _records = newItems;
          _isLoadingRecords = false;
        }
        _hasMoreRecords = hasMore;
        _recordsNextCursor =
            nextCursor ?? (newItems.isNotEmpty ? newItems.last.id : null);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        if (loadMore) {
          _isLoadingMoreRecords = false;
        } else {
          _isLoadingRecords = false;
        }
        _recordsError = GovernanceApiErrorMapper.format(e, fallback: '加载治理记录失败');
      });
    }
  }

  // ==========================================
  // 课程合并工作流方法
  // ==========================================

  void _swapCourseDirection() {
    setState(() {
      final temp = _sourceCourse;
      _sourceCourse = _targetCourse;
      _targetCourse = temp;
      _courseMergeStep = 0;
      _coursePreview = null;
      _coursePreviewError = null;
      _courseTeacherPairings.clear();
      _courseTeacherFinalNames.clear();
      _sourceCourseTeachers.clear();
      _targetCourseTeachers.clear();
    });
  }

  Future<void> _goToCourseMergeStep1() async {
    if (_sourceCourse == null || _targetCourse == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先选择被合并课程和目标保留课程')),
      );
      return;
    }
    if (_sourceCourse!.id == _targetCourse!.id) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('被合并课程与目标课程不能是同一个')),
      );
      return;
    }

    setState(() {
      _isLoadingCourseTeachers = true;
      _courseTeachersError = null;
    });

    try {
      final dio = context.read<AuthProvider>().dio;
      final resSource = await dio.get(
        '/admin/teacher-governance/teachers',
        queryParameters: {
          'subject_id': _sourceCourse!.id,
          'include_merged': false,
        },
      );
      final resTarget = await dio.get(
        '/admin/teacher-governance/teachers',
        queryParameters: {
          'subject_id': _targetCourse!.id,
          'include_merged': false,
        },
      );

      final sourceItems = _extractList(resSource.data, 'teachers')
          .whereType<Map<String, dynamic>>()
          .map(TeacherGovernanceTeacherItem.fromJson)
          .toList();
      final targetItems = _extractList(resTarget.data, 'teachers')
          .whereType<Map<String, dynamic>>()
          .map(TeacherGovernanceTeacherItem.fromJson)
          .toList();

      setState(() {
        _sourceCourseTeachers = sourceItems;
        _targetCourseTeachers = targetItems;
        _finalCourseNameCtrl.text = _targetCourse!.name;
        _courseTeacherPairings.clear();
        _courseTeacherFinalNames.clear();

        // 默认匹配策略：若源课程教师与目标课程教师完全同名，预选配对；否则独立迁入
        for (final st in _sourceCourseTeachers) {
          final matchedTarget = _targetCourseTeachers
              .where((tt) =>
                  tt.name.trim().toLowerCase() ==
                  st.name.trim().toLowerCase())
              .firstOrNull;
          if (matchedTarget != null) {
            _courseTeacherPairings[st.id] = matchedTarget.id;
            _courseTeacherFinalNames[st.id] = matchedTarget.name;
          } else {
            _courseTeacherPairings[st.id] = null; // 独立迁入保留
            _courseTeacherFinalNames[st.id] = st.name;
          }
        }

        _isLoadingCourseTeachers = false;
        _courseMergeStep = 1;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoadingCourseTeachers = false;
        _courseTeachersError = '加载课程授课教师失败: $e';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('加载教师失败: $e'), backgroundColor: Colors.red),
      );
    }
  }

  Future<void> _fetchCourseMergePreview() async {
    final finalName = _finalCourseNameCtrl.text.trim();
    if (finalName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请填写合并后的规范课程名称')),
      );
      return;
    }
    final reason = _courseMergeReasonCtrl.text.trim();
    if (reason.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请填写合并治理原因')),
      );
      return;
    }

    setState(() {
      _isLoadingCoursePreview = true;
      _coursePreviewError = null;
    });

    try {
      final dio = context.read<AuthProvider>().dio;
      final teacherPairsPayload = <Map<String, dynamic>>[];
      for (final entry in _courseTeacherPairings.entries) {
        if (entry.value != null) {
          final sourceId = entry.key;
          final targetId = entry.value!;
          final finalTeacherName =
              _courseTeacherFinalNames[sourceId]?.trim() ?? '';
          teacherPairsPayload.add({
            'loser_teacher_id': sourceId,
            'keeper_teacher_id': targetId,
            if (finalTeacherName.isNotEmpty)
              'final_teacher_name': finalTeacherName,
          });
        }
      }

      final payload = {
        'keeper_subject_id': _targetCourse!.id,
        'loser_subject_ids': [_sourceCourse!.id],
        'final_course_name': finalName,
        'register_course_aliases': _registerCourseAlias,
        'teacher_pairs': teacherPairsPayload,
      };

      final res = await dio.post(
        '/admin/teacher-governance/course-merge-preview',
        data: payload,
      );

      if (!mounted) return;
      final data = res.data;
      if (data is Map) {
        setState(() {
          _coursePreview = CourseMergePreviewResult.fromJson(
            Map<String, dynamic>.from(data),
          );
          _isLoadingCoursePreview = false;
          _courseMergeStep = 2;
        });
      } else {
        setState(() {
          _isLoadingCoursePreview = false;
          _coursePreviewError = '预览响应格式异常';
        });
      }
    } on DioException catch (e) {
      if (!mounted) return;
      final err = e.response?.data is Map ? e.response?.data['error'] : null;
      setState(() {
        _isLoadingCoursePreview = false;
        _coursePreviewError = err?.toString() ?? '预览失败: ${e.message}';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_coursePreviewError!),
          backgroundColor: Colors.red,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoadingCoursePreview = false;
        _coursePreviewError = '预览异常: $e';
      });
    }
  }

  Future<void> _executeCourseMerge() async {
    if (_coursePreview == null || !_coursePreview!.mergeAllowed) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认执行课程合并'),
        content: Text(
          '将把「${_sourceCourse!.name}」(#${_sourceCourse!.id}) 并入「${_targetCourse!.name}」(#${_targetCourse!.id})。\n\n'
          '• 合并后课程标准名称：${_coursePreview!.finalCourseName}\n'
          '• 独立迁入教师：${_coursePreview!.migratingTeachers.length} 位\n'
          '• 教师条目合并：${_coursePreview!.pairedTeacherMerges.length} 对\n'
          '• 评价迁移：${_coursePreview!.ratingsMigrated} 条 (去重归档 ${_coursePreview!.ratingsSoftDeleted} 条)\n\n'
          '此操作不可逆，请确认是否继续？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.brandPrimary),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('确认合并为「${_coursePreview!.finalCourseName}」'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() {
      _isExecutingCourseMerge = true;
    });

    try {
      final dio = context.read<AuthProvider>().dio;
      final teacherPairsPayload = <Map<String, dynamic>>[];
      for (final entry in _courseTeacherPairings.entries) {
        if (entry.value != null) {
          final sourceId = entry.key;
          final targetId = entry.value!;
          final finalTeacherName =
              _courseTeacherFinalNames[sourceId]?.trim() ?? '';
          teacherPairsPayload.add({
            'loser_teacher_id': sourceId,
            'keeper_teacher_id': targetId,
            if (finalTeacherName.isNotEmpty)
              'final_teacher_name': finalTeacherName,
          });
        }
      }

      final payload = {
        'keeper_subject_id': _targetCourse!.id,
        'loser_subject_ids': [_sourceCourse!.id],
        'final_course_name': _coursePreview!.finalCourseName,
        'register_course_aliases': _registerCourseAlias,
        'snapshot_token': _coursePreview!.snapshotToken,
        'reason': _courseMergeReasonCtrl.text.trim(),
        'teacher_pairs': teacherPairsPayload,
      };

      final res = await dio.post(
        '/admin/teacher-governance/course-merge',
        data: payload,
      );

      if (!mounted) return;
      final msg = res.data is Map && res.data['message'] != null
          ? res.data['message'].toString()
          : '课程合并成功！';

      // 清除客户端课程与教师缓存以确保榜单和详情重新加载规范数据
      _hasChanged = true;
      context.read<CourseSubjectProvider>().clearCache();
      try {
        context.read<TeacherProvider>().clearCache();
      } catch (_) {}

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), backgroundColor: Colors.green),
      );

      setState(() {
        _isExecutingCourseMerge = false;
        _courseMergeStep = 0;
        _sourceCourse = null;
        _targetCourse = null;
        _coursePreview = null;
        _sourceCourseTeachers.clear();
        _targetCourseTeachers.clear();
        _courseTeacherPairings.clear();
        _courseTeacherFinalNames.clear();
      });

      _loadRecords();
    } on DioException catch (e) {
      if (!mounted) return;
      setState(() {
        _isExecutingCourseMerge = false;
      });
      final data = e.response?.data;
      final code = data is Map ? data['code']?.toString() : null;
      final err = data is Map ? data['error']?.toString() : null;

      if (code == 'GOVERNANCE_SNAPSHOT_STALE') {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('数据快照已过期，请重新计算影响预览'),
            backgroundColor: Colors.orange,
          ),
        );
        _fetchCourseMergePreview();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(err ?? '课程合并执行失败: ${e.message}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isExecutingCourseMerge = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('合并执行失败: $e'), backgroundColor: Colors.red),
      );
    }
  }

  // ==========================================
  // 别名增删
  // ==========================================

  Future<void> _showAddAliasDialog() async {
    final aliasCtrl = TextEditingController();
    AliasTargetItem? selectedTeacher;
    AliasTargetItem? selectedSubject;

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
                  _AliasTargetPicker(
                    label: '目标教师（必选）',
                    hint: '按姓名或课程搜索',
                    targetType: 'teacher',
                    selected: selectedTeacher,
                    onSelected: (item) => setDialogState(
                        () => selectedTeacher = item.id == 0 ? null : item),
                  ),
                  const SizedBox(height: 12),
                ] else ...[
                  _AliasTargetPicker(
                    label: '目标学科（必选）',
                    hint: '按课程名搜索',
                    targetType: 'course',
                    selected: selectedSubject,
                    onSelected: (item) => setDialogState(
                        () => selectedSubject = item.id == 0 ? null : item),
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
                  if (selectedTeacher == null) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('请选择目标教师')),
                    );
                    return;
                  }
                } else {
                  if (selectedSubject == null) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('请选择目标学科')),
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
                  };
                  if (_aliasType == 'teacher') {
                    payload['teacher_id'] = selectedTeacher!.id;
                  } else {
                    payload['course_subject_id'] = selectedSubject!.id;
                  }
                  await dio.post(
                    '/admin/teacher-governance/aliases',
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
        '/admin/teacher-governance/aliases/${item.id}',
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
  // 教师合并 BottomSheet
  // ==========================================

  void _openTeacherMergeSheet(
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
          _hasChanged = true;
          context.read<CourseSubjectProvider>().clearCache();
          try {
            context.read<TeacherProvider>().clearCache();
          } catch (_) {}
          _loadCandidateGroups();
          _loadTeachers();
          _loadRecords();
          setState(() {
            _selectedTeachers.clear();
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

    if (_isCheckingCapability) {
      return Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.of(context).pop(_hasChanged),
          ),
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
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_serverUnsupported) {
      return Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.of(context).pop(_hasChanged),
          ),
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
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.xxl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.cloud_sync_outlined,
                    size: 56, color: Colors.orange),
                const SizedBox(height: AppSpacing.md),
                Text(
                  '服务端尚未升级',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: isDark ? Colors.white : AppColors.textPrimaryLight,
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  '当前连接的服务端版本未提供教师与课程治理能力（teacher_governance_v1）。\n请联系系统管理员部署包含治理后端的版本后再试。',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    color: isDark ? Colors.white70 : Colors.black54,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                FilledButton.icon(
                  onPressed: _checkServerCapabilities,
                  icon: const Icon(Icons.refresh),
                  label: const Text('重新检测能力'),
                  style: FilledButton.styleFrom(
                      backgroundColor: AppColors.brandPrimary),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        Navigator.of(context).pop(_hasChanged);
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.of(context).pop(_hasChanged),
          ),
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
          labelPadding: const EdgeInsets.symmetric(horizontal: 4),
          tabs: [
            const Tab(text: '课程合并'),
            const Tab(text: '教师合并'),
            const Tab(text: '处理记录'),
            const Tab(text: '别名管理'),
            Tab(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text('疑似推荐'),
                  if (_candidateGroups.isNotEmpty) ...[
                    const SizedBox(width: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 5, vertical: 1),
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
          ],
        ),
      ),
      body: SafeArea(
        top: false,
        child: TabBarView(
          controller: _tabController,
          children: [
            _buildCourseMergeTab(isDark),
            _buildAllTeachersTab(isDark),
            _buildRecordsTab(isDark),
            _buildAliasesTab(isDark),
            _buildDuplicateGroupsTab(isDark),
          ],
        ),
      ),
    ),
  );
}

  // ============================================================================
  // Tab 0: 课程合并 (选择对象 → 确认名称与教师对应 → 预览并执行)
  // ============================================================================

  Widget _buildCourseMergeTab(bool isDark) {
    return Column(
      children: [
        // 步骤进度条
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: isDark ? AppColors.surfaceSecondaryDark : Colors.white,
            border: Border(
              bottom: BorderSide(
                color: isDark ? Colors.white12 : AppColors.borderNormalLight,
              ),
            ),
          ),
          child: Row(
            children: [
              _buildStepIndicator(0, '1. 选择课程', _courseMergeStep >= 0,
                  _courseMergeStep == 0, isDark),
              const Expanded(child: Divider(indent: 8, endIndent: 8)),
              _buildStepIndicator(1, '2. 确认对应', _courseMergeStep >= 1,
                  _courseMergeStep == 1, isDark),
              const Expanded(child: Divider(indent: 8, endIndent: 8)),
              _buildStepIndicator(2, '3. 预览执行', _courseMergeStep >= 2,
                  _courseMergeStep == 2, isDark),
            ],
          ),
        ),
        // 步骤主内容
        Expanded(
          child: switch (_courseMergeStep) {
            0 => _buildCourseMergeStep0(isDark),
            1 => _buildCourseMergeStep1(isDark),
            2 => _buildCourseMergeStep2(isDark),
            _ => const SizedBox.shrink(),
          },
        ),
      ],
    );
  }

  Widget _buildStepIndicator(int stepIndex, String title, bool isCompleted,
      bool isActive, bool isDark) {
    const activeColor = AppColors.brandPrimary;
    final inactiveColor = isDark ? Colors.white38 : Colors.grey;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        CircleAvatar(
          radius: 10,
          backgroundColor:
              isActive || isCompleted ? activeColor : inactiveColor.withValues(alpha: 0.2),
          child: Text(
            '${stepIndex + 1}',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              color: isActive || isCompleted ? Colors.white : inactiveColor,
            ),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          title,
          style: TextStyle(
            fontSize: 12,
            fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
            color: isActive
                ? activeColor
                : (isDark ? Colors.white70 : Colors.black87),
          ),
        ),
      ],
    );
  }

  // Step 0: 选择合并对象与方向
  Widget _buildCourseMergeStep0(bool isDark) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 提示条
          Container(
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color: AppColors.brandPrimary.withValues(alpha: isDark ? 0.15 : 0.08),
              borderRadius: BorderRadius.circular(AppRadius.md),
              border: Border.all(
                color: AppColors.brandPrimary.withValues(alpha: 0.3),
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.info_outline,
                    size: 18, color: AppColors.brandPrimary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '说明：课程合并将统一课程标准名称与归属。源课程下的不同教师将独立迁移至目标课程名下（不强制合并不同教师）。如确有重名教师，可在下一步明确合并对应。',
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.4,
                      color: isDark ? Colors.white70 : AppColors.textPrimaryLight,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // 被合并课程 (loser)
          _buildCourseSelectCard(
            title: '被合并课程（归并源，将被重定向）',
            badgeText: '归并源',
            badgeBg: Colors.red.withValues(alpha: 0.15),
            badgeColor: Colors.red,
            course: _sourceCourse,
            onPick: () => _openCoursePickerModal(isSource: true),
            onClear: () => setState(() => _sourceCourse = null),
            isDark: isDark,
          ),

          // 交换方向按钮
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Center(
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                ),
                onPressed: (_sourceCourse != null && _targetCourse != null)
                    ? _swapCourseDirection
                    : null,
                icon: const Icon(Icons.swap_vert_rounded, size: 18),
                label: const Text('交换合并方向'),
              ),
            ),
          ),

          // 目标保留课程 (keeper)
          _buildCourseSelectCard(
            title: '目标保留课程（保留实体，数据汇入）',
            badgeText: '保留实体',
            badgeBg: Colors.green.withValues(alpha: 0.15),
            badgeColor: Colors.green,
            course: _targetCourse,
            onPick: () => _openCoursePickerModal(isSource: false),
            onClear: () => setState(() => _targetCourse = null),
            isDark: isDark,
          ),

          const SizedBox(height: 24),

          // 下一步按钮
          SizedBox(
            width: double.infinity,
            height: 48,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.brandPrimary,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
              ),
              onPressed: (_sourceCourse != null &&
                      _targetCourse != null &&
                      _sourceCourse!.id != _targetCourse!.id &&
                      !_isLoadingCourseTeachers)
                  ? _goToCourseMergeStep1
                  : null,
              child: _isLoadingCourseTeachers
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Text(
                      '下一步：确认名称与教师对应关系',
                      style:
                          TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCourseSelectCard({
    required String title,
    required String badgeText,
    required Color badgeBg,
    required Color badgeColor,
    required GovernanceCourseItem? course,
    required VoidCallback onPick,
    required VoidCallback onClear,
    required bool isDark,
  }) {
    return Card(
      margin: EdgeInsets.zero,
      color: isDark ? AppColors.surfaceSecondaryDark : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        side: BorderSide(
          color: course != null
              ? badgeColor.withValues(alpha: 0.4)
              : (isDark ? Colors.white12 : AppColors.borderNormalLight),
          width: course != null ? 1.5 : 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: badgeBg,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    badgeText,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: badgeColor,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (course != null) ...[
              Row(
                children: [
                  CircleAvatar(
                    radius: 18,
                    backgroundColor: badgeColor.withValues(alpha: 0.15),
                    child: Icon(Icons.school_rounded,
                        size: 20, color: badgeColor),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          course.name,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'ID: #${course.id} · ${course.teacherCount} 位授课教师 · ${course.ratingCount} 条评价',
                          style: TextStyle(
                            fontSize: 12,
                            color: isDark ? Colors.white60 : Colors.black54,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: '更换课程',
                    icon: const Icon(Icons.swap_horiz, size: 20),
                    onPressed: onPick,
                  ),
                  IconButton(
                    tooltip: '清除',
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: onClear,
                  ),
                ],
              ),
            ] else ...[
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(double.infinity, 48),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                ),
                onPressed: onPick,
                icon: const Icon(Icons.search, size: 18),
                label: const Text('点击搜索并选择课程'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _openCoursePickerModal({required bool isSource}) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _GovernanceCoursePickerModal(
        title: isSource ? '选择被合并课程（归并源）' : '选择目标保留课程（保留实体）',
        onSelected: (selected) {
          setState(() {
            if (isSource) {
              _sourceCourse = selected;
            } else {
              _targetCourse = selected;
            }
          });
        },
      ),
    );
  }

  // Step 1: 确认名称与教师对应关系
  Widget _buildCourseMergeStep1(bool isDark) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_courseTeachersError != null) ...[
            Container(
              padding: const EdgeInsets.all(AppSpacing.md),
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: Colors.red.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
              child: Row(
                children: [
                  const Icon(Icons.error_outline, color: Colors.red, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _courseTeachersError!,
                      style: const TextStyle(color: Colors.red),
                    ),
                  ),
                  TextButton(
                    onPressed: _goToCourseMergeStep1,
                    child: const Text('重试'),
                  ),
                ],
              ),
            ),
          ],
          // 概览
          Card(
            margin: EdgeInsets.zero,
            color: isDark ? AppColors.surfaceSecondaryDark : Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.md),
              side: BorderSide(
                color: isDark ? Colors.white12 : AppColors.borderNormalLight,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '「${_sourceCourse!.name}」',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Colors.red,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const Icon(Icons.arrow_forward_rounded,
                      size: 20, color: Colors.grey),
                  Expanded(
                    child: Text(
                      '「${_targetCourse!.name}」',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Colors.green,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // 1. 合并后的规范课程名
          Text(
            '1. 确认合并后的标准课程名称',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: isDark ? Colors.white : AppColors.textPrimaryLight,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '默认采用目标保留课程名，可点击快捷按钮选用原名或直接输入规范名称：',
            style: TextStyle(
              fontSize: 12,
              color: isDark ? Colors.white60 : Colors.black54,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _finalCourseNameCtrl,
            decoration: InputDecoration(
              labelText: '最终标准课程名 (必填)',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
              prefixIcon: const Icon(Icons.edit_note, size: 20),
            ),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            children: [
              ActionChip(
                label: Text('使用目标名: ${_targetCourse!.name}'),
                onPressed: () {
                  setState(() {
                    _finalCourseNameCtrl.text = _targetCourse!.name;
                  });
                },
              ),
              ActionChip(
                label: Text('使用原名: ${_sourceCourse!.name}'),
                onPressed: () {
                  setState(() {
                    _finalCourseNameCtrl.text = _sourceCourse!.name;
                  });
                },
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isDark
                  ? AppColors.surfaceSecondaryDark
                  : AppColors.brandPrimary.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(AppRadius.md),
              border: Border.all(
                color: AppColors.brandPrimary.withValues(alpha: 0.25),
              ),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.info_outline_rounded,
                  size: 18,
                  color: AppColors.brandPrimary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '已开启规范回流：原课程名「${_sourceCourse!.name}」将自动登记为目标规范别名，旧课表提评与搜索无缝重定向。',
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark
                          ? Colors.white70
                          : AppColors.textPrimaryLight,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),

          const Divider(height: 24),

          // 2. 授课教师迁移与合并方案
          Row(
            children: [
              Text(
                '2. 授课教师迁移与合并规划',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: isDark ? Colors.white : AppColors.textPrimaryLight,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: AppColors.brandPrimary.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '${_sourceCourseTeachers.length} 位源教师',
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppColors.brandPrimary,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '源课程下的不同教师迁入目标后将独立保留；若确认为同一位教师，请选择合并目标并去重评价：',
            style: TextStyle(
              fontSize: 12,
              color: isDark ? Colors.white60 : Colors.black54,
            ),
          ),
          const SizedBox(height: 12),

          if (_sourceCourseTeachers.isEmpty) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(AppSpacing.md),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9),
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
              child: const Text(
                '原课程下暂无活动授课教师，合并将直接归并课程实体元数据并重定向旧 ID。',
                style: TextStyle(fontSize: 12.5),
              ),
            ),
          ] else ...[
            ..._sourceCourseTeachers.map((st) {
              final pairedTargetId = _courseTeacherPairings[st.id];
              final isPaired = pairedTargetId != null;

              return Card(
                margin: const EdgeInsets.only(bottom: 10),
                color: isDark ? AppColors.surfaceSecondaryDark : Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  side: BorderSide(
                    color: isPaired
                        ? AppColors.brandPrimary.withValues(alpha: 0.5)
                        : (isDark ? Colors.white12 : AppColors.borderNormalLight),
                    width: isPaired ? 1.5 : 1,
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          CircleAvatar(
                            radius: 12,
                            child: Text(st.name.isNotEmpty ? st.name[0] : '?',
                                style: const TextStyle(fontSize: 11)),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            st.name,
                            style: const TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 14),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '#${st.id} · ${st.ratingCount} 条评价',
                            style: TextStyle(
                              fontSize: 12,
                              color: isDark ? Colors.white60 : Colors.black54,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      // 单选：独立迁入 vs 合并
                      Row(
                        children: [
                          ChoiceChip(
                            label: const Text('独立迁入目标课程 (推荐)'),
                            selected: !isPaired,
                            onSelected: (val) {
                              if (val) {
                                setState(() {
                                  _courseTeacherPairings[st.id] = null;
                                  _courseTeacherFinalNames[st.id] = st.name;
                                });
                              }
                            },
                          ),
                          const SizedBox(width: 8),
                          ChoiceChip(
                            label: const Text('与目标教师合并'),
                            selected: isPaired,
                            onSelected: (val) {
                              if (val && _targetCourseTeachers.isNotEmpty) {
                                setState(() {
                                  // 选第一个或名字同名的目标教师
                                  final match = _targetCourseTeachers
                                      .where((tt) =>
                                          tt.name.trim() == st.name.trim())
                                      .firstOrNull;
                                  final chosen =
                                      match ?? _targetCourseTeachers.first;
                                  _courseTeacherPairings[st.id] = chosen.id;
                                  _courseTeacherFinalNames[st.id] = chosen.name;
                                });
                              }
                            },
                          ),
                        ],
                      ),
                      if (isPaired) ...[
                        const SizedBox(height: 10),
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: isDark
                                ? const Color(0xFF1E293B)
                                : const Color(0xFFF1F5F9),
                            borderRadius: BorderRadius.circular(AppRadius.sm),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              DropdownButtonFormField<int>(
                                initialValue: pairedTargetId,
                                decoration: const InputDecoration(
                                  labelText: '选择目标保留教师',
                                  isDense: true,
                                  border: OutlineInputBorder(),
                                ),
                                items: _targetCourseTeachers.map((tt) {
                                  return DropdownMenuItem<int>(
                                    value: tt.id,
                                    child: Text(
                                        '${tt.name} (#${tt.id}, ${tt.ratingCount} 评价)'),
                                  );
                                }).toList(),
                                onChanged: (val) {
                                  if (val != null) {
                                    setState(() {
                                      _courseTeacherPairings[st.id] = val;
                                      final target = _targetCourseTeachers
                                          .firstWhere((tt) => tt.id == val);
                                      _courseTeacherFinalNames[st.id] =
                                          target.name;
                                    });
                                  }
                                },
                              ),
                              const SizedBox(height: 8),
                              TextFormField(
                                initialValue:
                                    _courseTeacherFinalNames[st.id] ?? st.name,
                                decoration: const InputDecoration(
                                  labelText: '合并后教师规范姓名',
                                  isDense: true,
                                  border: OutlineInputBorder(),
                                ),
                                onChanged: (val) {
                                  _courseTeacherFinalNames[st.id] = val;
                                },
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              );
            }),
          ],

          const Divider(height: 24),

          // 3. 合并原因
          Text(
            '3. 合并治理原因 (必填)',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: isDark ? Colors.white : AppColors.textPrimaryLight,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _courseMergeReasonCtrl,
            decoration: InputDecoration(
              labelText: '操作原因',
              hintText: '如：学科更名、不同写法合并、教务导入重复等',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
            ),
          ),

          const SizedBox(height: 24),

          // 按钮栏
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 48),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadius.md),
                    ),
                  ),
                  onPressed: () => setState(() => _courseMergeStep = 0),
                  child: const Text('上一步：重新选课'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.brandPrimary,
                    minimumSize: const Size(0, 48),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadius.md),
                    ),
                  ),
                  onPressed: _isLoadingCoursePreview
                      ? null
                      : _fetchCourseMergePreview,
                  child: _isLoadingCoursePreview
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Text(
                          '下一步：计算影响并预览',
                          style: TextStyle(
                              fontSize: 15, fontWeight: FontWeight.bold),
                        ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // Step 2: 预览影响与确认执行
  Widget _buildCourseMergeStep2(bool isDark) {
    if (_isLoadingCoursePreview) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_coursePreviewError != null) {
      return _buildErrorState(
        _coursePreviewError!,
        _fetchCourseMergePreview,
        isDark,
      );
    }

    if (_coursePreview == null) {
      return const Center(child: Text('无可用预览数据'));
    }

    final p = _coursePreview!;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 头部执行决策卡
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9),
              borderRadius: BorderRadius.circular(AppRadius.lg),
              border: Border.all(
                color: isDark ? Colors.white12 : AppColors.borderNormalLight,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.rule_folder_rounded,
                        color: AppColors.brandPrimary),
                    const SizedBox(width: 8),
                    Text(
                      '将「${_sourceCourse!.name}」并入「${_targetCourse!.name}」',
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  '• 合并后统一规范课程名：${p.finalCourseName}',
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600),
                ),
                Text(
                  '• 目标课程保留实体 ID：#${p.keeperSubject.id}',
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark ? Colors.white70 : Colors.black87,
                  ),
                ),
                Text(
                  '• 源课程 #${p.loserSubjects.first.id} 将被重定向，后续访问自动解析至目标',
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark ? Colors.white60 : Colors.black54,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // 指标卡网格
          Container(
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF1B232D) : const Color(0xFFF8FAFC),
              borderRadius: BorderRadius.circular(AppRadius.md),
              border: Border.all(
                color: isDark ? Colors.white12 : Colors.black12,
              ),
            ),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: _buildMetricItem(
                        '独立迁入教师',
                        '${p.migratingTeachers.length} 位',
                        isDark,
                      ),
                    ),
                    Expanded(
                      child: _buildMetricItem(
                        '合并教师对数',
                        '${p.pairedTeacherMerges.length} 对',
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
                        '迁移评价总数',
                        '${p.ratingsMigrated} 条',
                        isDark,
                      ),
                    ),
                    Expanded(
                      child: _buildMetricItem(
                        '冲突去重归档',
                        '${p.ratingsSoftDeleted} 条',
                        isDark,
                        color: p.ratingsSoftDeleted > 0 ? Colors.orange : null,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: _buildMetricItem(
                        '迁移投票记录',
                        '${p.votesMigrated} 票',
                        isDark,
                      ),
                    ),
                    Expanded(
                      child: _buildMetricItem(
                        '归并待审/提交',
                        '${p.submissionsSuperseded} 条',
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
                        '课程别名注册',
                        '${p.courseAliasesAdded} 个',
                        isDark,
                      ),
                    ),
                    Expanded(
                      child: _buildMetricItem(
                        '教师别名注册',
                        '${p.teacherAliasesAdded} 个',
                        isDark,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // 冲突或去重警示
          if (p.ratingConflicts.isNotEmpty) ...[
            Container(
              padding: const EdgeInsets.all(AppSpacing.md),
              decoration: BoxDecoration(
                color: Colors.amber.withValues(alpha: isDark ? 0.2 : 0.1),
                borderRadius: BorderRadius.circular(AppRadius.md),
                border: Border.all(color: Colors.amber),
              ),
              child: Row(
                children: [
                  const Icon(Icons.warning_amber_rounded,
                      color: Colors.amber, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '发现 ${p.ratingConflicts.length} 组用户在合并教师对上重复评价，系统将自动保留最新有效评价并归档重复记录。',
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark ? Colors.amber[200] : Colors.amber[900],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],

          // 详细明细折叠/列表
          if (p.migratingTeachers.isNotEmpty) ...[
            Text(
              '独立迁入教师 (${p.migratingTeachers.length} 位):',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
            const SizedBox(height: 4),
            ...p.migratingTeachers.map((mt) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      const Icon(Icons.arrow_right, size: 16, color: Colors.grey),
                      Text('${mt.teacherName} (原 #${mt.teacherId})'),
                      const SizedBox(width: 6),
                      Text('• ${mt.ratingCount} 评价',
                          style: const TextStyle(fontSize: 11, color: Colors.grey)),
                    ],
                  ),
                )),
            const SizedBox(height: 10),
          ],

          if (p.pairedTeacherMerges.isNotEmpty) ...[
            Text(
              '确认合并教师对 (${p.pairedTeacherMerges.length} 对):',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
            const SizedBox(height: 4),
            ...p.pairedTeacherMerges.map((ptm) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: isDark ? Colors.white10 : Colors.black.withValues(alpha: 0.04),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Row(
                      children: [
                        Text(
                          '${ptm.loserTeacherName} (#${ptm.loserTeacherId})',
                          style: const TextStyle(
                              decoration: TextDecoration.lineThrough,
                              color: Colors.grey),
                        ),
                        const SizedBox(width: 6),
                        const Icon(Icons.arrow_forward, size: 12, color: Colors.grey),
                        const SizedBox(width: 6),
                        Text(
                          '${ptm.keeperTeacherName} (#${ptm.keeperTeacherId})',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        const Spacer(),
                        Text(
                          '统一为「${ptm.finalTeacherName}」',
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppColors.brandPrimary,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                )),
            const SizedBox(height: 16),
          ],

          // 阻塞提示
          if (!p.mergeAllowed && p.blockReason.isNotEmpty) ...[
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
                      p.blockReason,
                      style: const TextStyle(
                          color: Colors.red, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],

          // 底部操作栏
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 48),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadius.md),
                    ),
                  ),
                  onPressed: () => setState(() => _courseMergeStep = 1),
                  child: const Text('返回修改配置'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.brandPrimary,
                    minimumSize: const Size(0, 48),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadius.md),
                    ),
                  ),
                  onPressed: (!p.mergeAllowed || _isExecutingCourseMerge)
                      ? null
                      : _executeCourseMerge,
                  child: _isExecutingCourseMerge
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : Text(
                          '确认合并为「${p.finalCourseName}」',
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ============================================================================
  // Tab 1: 全部教师 (跨搜索多选合并)
  // ============================================================================

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
                    _teacherSearchDebounce?.cancel();
                    _teacherSearchDebounce =
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
                          onRefresh: () => _loadTeachers(),
                          child: ListView.separated(
                            controller: _teacherScrollController,
                            padding: const EdgeInsets.all(AppSpacing.md),
                            itemCount: _allTeachers.length +
                                (_hasMoreTeachers || _isLoadingMoreTeachers
                                    ? 1
                                    : 0),
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 8),
                            itemBuilder: (ctx, index) {
                              if (index == _allTeachers.length) {
                                return Padding(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 16),
                                  child: Center(
                                    child: _isLoadingMoreTeachers
                                        ? const SizedBox(
                                            width: 20,
                                            height: 20,
                                            child: CircularProgressIndicator(
                                                strokeWidth: 2),
                                          )
                                        : TextButton(
                                            onPressed: () =>
                                                _loadTeachers(loadMore: true),
                                            child: const Text('加载更多教师'),
                                          ),
                                  ),
                                );
                              }
                              final t = _allTeachers[index];
                              final isSelected =
                                  _selectedTeachers.containsKey(t.id);
                              return _buildTeacherListItem(
                                  t, isSelected, isDark);
                            },
                          ),
                        ),
        ),
        // 底部多选治理浮动栏 (跨搜索选择保留)
        if (_selectedTeachers.length >= 2) ...[
          Container(
            padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md, vertical: 10),
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
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      '已跨搜索选中 ${_selectedTeachers.length} 位教师',
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 13),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: () {
                        setState(() {
                          _selectedTeachers.clear();
                        });
                      },
                      child: const Text('清空选择'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.brandPrimary,
                      ),
                      onPressed: () {
                        _openTeacherMergeSheet(
                            context, _selectedTeachers.values.toList());
                      },
                      icon: const Icon(Icons.merge_type_rounded, size: 16),
                      label: const Text('发起合并治理'),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                // 已选教师 Chips (支持跨搜索查看并移除)
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: _selectedTeachers.values.map((t) {
                      return Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: Chip(
                          padding: EdgeInsets.zero,
                          labelPadding:
                              const EdgeInsets.symmetric(horizontal: 6),
                          avatar: CircleAvatar(
                            radius: 10,
                            child: Text(
                              t.name.isNotEmpty ? t.name[0] : '?',
                              style: const TextStyle(fontSize: 10),
                            ),
                          ),
                          label: Text(
                            '${t.name} (${t.subjectName.isNotEmpty ? t.subjectName : t.course})',
                            style: const TextStyle(fontSize: 12),
                          ),
                          deleteIcon: const Icon(Icons.close, size: 14),
                          onDeleted: () {
                            setState(() {
                              _selectedTeachers.remove(t.id);
                            });
                          },
                        ),
                      );
                    }).toList(),
                  ),
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
                      _selectedTeachers[t.id] = t;
                    } else {
                      _selectedTeachers.remove(t.id);
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
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
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

  // ============================================================================
  // Tab 2: 处理记录
  // ============================================================================

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
        '完成课程合并、教师合并或别名收敛后，审计记录将呈现在这里。',
        _loadRecords,
        isDark,
      );
    }

    // 按 batch_id 分组
    final batchMap = <String, List<TeacherMergeRecordItem>>{};
    for (final r in _records) {
      batchMap.putIfAbsent(r.batchId, () => []).add(r);
    }

    final batchKeys = batchMap.keys.toList();
    return RefreshIndicator(
      onRefresh: () => _loadRecords(),
      child: ListView.builder(
        controller: _recordsScrollController,
        padding: const EdgeInsets.all(AppSpacing.md),
        itemCount:
            batchKeys.length + (_hasMoreRecords || _isLoadingMoreRecords ? 1 : 0),
        itemBuilder: (ctx, index) {
          if (index == batchKeys.length) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Center(
                child: _isLoadingMoreRecords
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : TextButton(
                        onPressed: () => _loadRecords(loadMore: true),
                        child: const Text('加载更多记录'),
                      ),
              ),
            );
          }
          final batchId = batchKeys[index];
          final batchRecords = batchMap[batchId]!;
          final first = batchRecords.first;
          final isCourseAction =
              first.action == 'course_merge' || first.action == 'course';

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
                      Icon(
                        isCourseAction
                            ? Icons.school_rounded
                            : Icons.history_edu_rounded,
                        size: 18,
                        color: isCourseAction
                            ? Colors.blue
                            : AppColors.brandPrimary,
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: (isCourseAction ? Colors.blue : Colors.purple)
                              .withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          isCourseAction ? '课程合并' : '教师合并',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color:
                                isCourseAction ? Colors.blue : Colors.purple,
                          ),
                        ),
                      ),
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
                  if (first.reason.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      '原因说明: ${first.reason}',
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark ? Colors.white70 : Colors.black87,
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  const Divider(height: 1),
                  const SizedBox(height: 8),
                  // 合并条目
                  ...batchRecords.map((r) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${r.loserName} (${r.loserSubject})',
                              style: const TextStyle(
                                decoration: TextDecoration.lineThrough,
                                color: Colors.grey,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 6),
                          const Icon(Icons.arrow_forward,
                              size: 12, color: Colors.grey),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              '${r.keeperName} (${r.keeperSubject})',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                color: AppColors.brandPrimary,
                              ),
                              overflow: TextOverflow.ellipsis,
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

  // ============================================================================
  // Tab 3: 别名管理
  // ============================================================================

  Widget _buildAliasesTab(bool isDark) {
    return Column(
      children: [
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
              _aliasSearchDebounce?.cancel();
              _aliasSearchDebounce = Timer(const Duration(milliseconds: 300), () {
                setState(() {
                  _aliasSearchQuery = val;
                });
                _loadAliases();
              });
            },
          ),
        ),
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
                          onRefresh: () => _loadAliases(),
                          child: ListView.separated(
                            controller: _aliasesScrollController,
                            padding: const EdgeInsets.all(AppSpacing.md),
                            itemCount: _aliases.length +
                                (_hasMoreAliases || _isLoadingMoreAliases
                                    ? 1
                                    : 0),
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 8),
                            itemBuilder: (ctx, index) {
                              if (index == _aliases.length) {
                                return Padding(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 16),
                                  child: Center(
                                    child: _isLoadingMoreAliases
                                        ? const SizedBox(
                                            width: 20,
                                            height: 20,
                                            child: CircularProgressIndicator(
                                                strokeWidth: 2),
                                          )
                                        : TextButton(
                                            onPressed: () =>
                                                _loadAliases(loadMore: true),
                                            child: const Text('加载更多别名'),
                                          ),
                                  ),
                                );
                              }
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

  // ============================================================================
  // Tab 4: 疑似推荐
  // ============================================================================

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
                          color: isSuggested
                              ? Colors.white
                              : (isDark ? Colors.white70 : Colors.black87),
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
                            : '跨课程同名教师。请使用顶部的【课程合并】功能进行统筹治理。',
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
                      _openTeacherMergeSheet(
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

  // ==========================================
  // 通用状态组件
  // ==========================================

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

// ============================================================================
// 教师合并 BottomSheet 组件 (增强：明确保留谁、确认最终规范教师姓名、操作原因)
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

enum CrossSubjectDecision {
  unselected,
  teacherOnly,
  mergeSubject,
}

class _TeacherMergeBottomSheetState extends State<_TeacherMergeBottomSheet> {
  late int _keeperId;
  bool _registerAliases = true;
  CrossSubjectDecision _crossSubjectDecision = CrossSubjectDecision.unselected;

  final TextEditingController _finalTeacherNameCtrl = TextEditingController();
  final TextEditingController _reasonCtrl =
      TextEditingController(text: '同教师重名合并治理');

  bool get _isCrossSubject {
    final keeper = widget.teachers.firstWhere(
      (t) => t.id == _keeperId,
      orElse: () => widget.teachers.first,
    );
    final keeperSubj = keeper.subjectId;
    return widget.teachers
            .any((t) => t.id != _keeperId && t.subjectId != keeperSubj) ||
        (_preview != null && _preview!.courseMerges.isNotEmpty);
  }

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

    final initialKeeper = widget.teachers.firstWhere(
      (t) => t.id == _keeperId,
      orElse: () => widget.teachers.first,
    );
    _finalTeacherNameCtrl.text = initialKeeper.name;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _fetchPreview();
    });
  }

  @override
  void dispose() {
    _finalTeacherNameCtrl.dispose();
    _reasonCtrl.dispose();
    super.dispose();
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
      List<Map<String, dynamic>>? courseMergesPayload;
      if (_crossSubjectDecision != CrossSubjectDecision.unselected) {
        final mergeEntity =
            _crossSubjectDecision == CrossSubjectDecision.mergeSubject;
        if (_preview != null && _preview!.courseMerges.isNotEmpty) {
          courseMergesPayload = _preview!.courseMerges
              .map((cm) => {
                    'loser_subject_id': cm.loserSubjectId,
                    'keeper_subject_id': cm.keeperSubjectId,
                    'merge_subject_entity': mergeEntity,
                  })
              .toList();
        } else {
          final keeper = widget.teachers.firstWhere(
            (t) => t.id == _keeperId,
            orElse: () => widget.teachers.first,
          );
          final keeperSubj = keeper.subjectId;
          final loserSubjs = widget.teachers
              .where((t) => t.id != _keeperId && t.subjectId != keeperSubj)
              .map((t) => t.subjectId)
              .toSet();
          if (loserSubjs.isNotEmpty) {
            courseMergesPayload = loserSubjs
                .map((sid) => {
                      'loser_subject_id': sid,
                      'keeper_subject_id': keeperSubj,
                      'merge_subject_entity': mergeEntity,
                    })
                .toList();
          }
        }
      }

      final payload = {
        'keeper_id': _keeperId,
        'loser_ids': _loserIds,
        'register_teacher_aliases': _registerAliases,
        'final_teacher_name': _finalTeacherNameCtrl.text.trim(),
        if (courseMergesPayload != null) 'course_merges': courseMergesPayload,
      };

      final res = await dio.post(
        '/admin/teacher-governance/merge-preview',
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
    if (_isCrossSubject &&
        _crossSubjectDecision == CrossSubjectDecision.unselected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('请先明确选择跨课程处理方式'), backgroundColor: Colors.orange),
      );
      return;
    }
    final finalName = _finalTeacherNameCtrl.text.trim();
    if (finalName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请确认最终规范教师姓名')),
      );
      return;
    }
    final reason = _reasonCtrl.text.trim();
    if (reason.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请填写合并治理原因')),
      );
      return;
    }

    setState(() {
      _isSubmitting = true;
    });

    try {
      final dio = context.read<AuthProvider>().dio;
      final mergeEntity =
          _crossSubjectDecision == CrossSubjectDecision.mergeSubject;
      final courseMergesPayload =
          (_preview?.courseMerges ?? const []).map((cm) => {
                'loser_subject_id': cm.loserSubjectId,
                'keeper_subject_id': cm.keeperSubjectId,
                'merge_subject_entity': mergeEntity,
              }).toList();

      final payload = {
        'keeper_id': _keeperId,
        'loser_ids': _loserIds,
        'snapshot_token': _preview!.snapshotToken,
        'register_teacher_aliases': _registerAliases,
        'final_teacher_name': finalName,
        'reason': reason,
        'course_merges': courseMergesPayload,
      };

      final res = await dio.post(
        '/admin/teacher-governance/merge',
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

      if (code == 'GOVERNANCE_SNAPSHOT_STALE' ||
          code == 'GOVERNANCE_SNAPSHOT_REQUIRED') {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('数据已发生变化，请重新确认合并影响'),
            backgroundColor: Colors.orange,
          ),
        );
        _fetchPreview();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(err ?? '合并失败: ${e.message}'),
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
    final finalName = _finalTeacherNameCtrl.text.trim();

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.88,
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
          Container(
            margin: const EdgeInsets.only(top: 10, bottom: 6),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.grey.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
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
          Expanded(
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm,
                  AppSpacing.md, bottomInset + 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 第一部分：选择保留的实体 (Keeper)
                  Text(
                    '第一步：选择保留的主教师实体 (Keeper ID)',
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
                          final selected = widget.teachers
                              .firstWhere((t) => t.id == val);
                          _finalTeacherNameCtrl.text = selected.name;
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

                  // 第二部分：确认最终姓名与原因
                  Text(
                    '第二步：确认最终规范教师姓名与合并原因',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: isDark ? Colors.white70 : Colors.black87,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _finalTeacherNameCtrl,
                    decoration: InputDecoration(
                      labelText: '合并后的规范教师姓名 (必填)',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(AppRadius.md),
                      ),
                      prefixIcon: const Icon(Icons.person, size: 20),
                    ),
                    onChanged: (_) {
                      setState(() {});
                    },
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    children: widget.teachers.map((t) {
                      return ActionChip(
                        label: Text('使用「${t.name}」'),
                        onPressed: () {
                          setState(() {
                            _finalTeacherNameCtrl.text = t.name;
                          });
                        },
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _reasonCtrl,
                    decoration: InputDecoration(
                      labelText: '合并原因说明 (必填)',
                      hintText: '如：规范姓名重名合并、用户报送勘误等',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(AppRadius.md),
                      ),
                    ),
                  ),

                  const SizedBox(height: 12),
                  const Divider(height: 1),
                  const SizedBox(height: 12),

                  // 第三部分：实体影响预览
                  Text(
                    '第三步：影响评估预览',
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

                  if (_isCrossSubject) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(AppSpacing.md),
                      decoration: BoxDecoration(
                        color: isDark
                            ? const Color(0xFF1E293B)
                            : const Color(0xFFF1F5F9),
                        borderRadius: BorderRadius.circular(AppRadius.md),
                        border: Border.all(
                          color: _crossSubjectDecision ==
                                  CrossSubjectDecision.unselected
                              ? Colors.orange.withValues(alpha: 0.6)
                              : (isDark ? Colors.white12 : Colors.black12),
                          width: _crossSubjectDecision ==
                                  CrossSubjectDecision.unselected
                              ? 1.5
                              : 1.0,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.alt_route_rounded,
                                size: 18,
                                color: _crossSubjectDecision ==
                                        CrossSubjectDecision.unselected
                                    ? Colors.orange
                                    : AppColors.brandPrimary,
                              ),
                              const SizedBox(width: 8),
                              const Text(
                                '跨课程处理方式（必选）',
                                style: TextStyle(
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '所选教师归属于不同课程，请明确课程实体归属决策：',
                            style: TextStyle(
                              fontSize: 12,
                              color: isDark ? Colors.white60 : Colors.black54,
                            ),
                          ),
                          const SizedBox(height: 8),
                          RadioGroup<CrossSubjectDecision>(
                            groupValue: _crossSubjectDecision,
                            onChanged: (val) {
                              if (val != null) {
                                setState(() {
                                  _crossSubjectDecision = val;
                                });
                                _fetchPreview();
                              }
                            },
                            child: const Column(
                              children: [
                                RadioListTile<CrossSubjectDecision>(
                                  contentPadding: EdgeInsets.zero,
                                  activeColor: AppColors.brandPrimary,
                                  title: Text(
                                    '仅合并教师，保留两个课程实体',
                                    style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600),
                                  ),
                                  subtitle: Text(
                                    '被合并教师数据迁移至目标教师名下，原课程实体继续保留（适用于跨体系任教）',
                                    style: TextStyle(fontSize: 11.5),
                                  ),
                                  value: CrossSubjectDecision.teacherOnly,
                                ),
                                Divider(height: 12),
                                RadioListTile<CrossSubjectDecision>(
                                  contentPadding: EdgeInsets.zero,
                                  activeColor: AppColors.brandPrimary,
                                  title: Text(
                                    '同时归并课程实体',
                                    style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600),
                                  ),
                                  subtitle: Text(
                                    '在原课程无其他活动教师时，将原课程归并至保留教师课程',
                                    style: TextStyle(fontSize: 11.5),
                                  ),
                                  value: CrossSubjectDecision.mergeSubject,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
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
                        !_preview!.mergeAllowed ||
                        finalName.isEmpty ||
                        (_isCrossSubject &&
                            _crossSubjectDecision ==
                                CrossSubjectDecision.unselected))
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
                    : Text(
                        '确认合并为「${finalName.isNotEmpty ? finalName : "选定教师"}」',
                        style: const TextStyle(
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

// ============================================================================
// 课程选择 BottomSheet 模态框
// ============================================================================

class _GovernanceCoursePickerModal extends StatefulWidget {
  final String title;
  final ValueChanged<GovernanceCourseItem> onSelected;

  const _GovernanceCoursePickerModal({
    required this.title,
    required this.onSelected,
  });

  @override
  State<_GovernanceCoursePickerModal> createState() =>
      _GovernanceCoursePickerModalState();
}

class _GovernanceCoursePickerModalState
    extends State<_GovernanceCoursePickerModal> {
  final TextEditingController _ctrl = TextEditingController();
  Timer? _debounce;
  int _courseSearchGen = 0;
  CancelToken? _courseCancelToken;
  List<GovernanceCourseItem> _courses = [];
  bool _isLoading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _search('');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _courseCancelToken?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  void _onQueryChanged(String query) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      _search(query);
    });
  }

  Future<void> _search(String query) async {
    _courseCancelToken?.cancel();
    _courseCancelToken = CancelToken();
    final cancelToken = _courseCancelToken;
    final currentGen = ++_courseSearchGen;

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final dio = context.read<AuthProvider>().dio;
      final res = await dio.get(
        '/admin/teacher-governance/courses',
        queryParameters: {
          if (query.trim().isNotEmpty) 'q': query.trim(),
        },
        cancelToken: cancelToken,
      );
      if (!mounted || currentGen != _courseSearchGen) return;
      final raw = res.data is Map
          ? (res.data['courses'] ?? res.data['items'] ?? [])
          : (res.data is List ? res.data : []);
      setState(() {
        _courses = (raw as List)
            .whereType<Map<String, dynamic>>()
            .map(GovernanceCourseItem.fromJson)
            .toList();
        _isLoading = false;
      });
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) return;
      if (!mounted || currentGen != _courseSearchGen) return;
      setState(() {
        _isLoading = false;
        _error = GovernanceApiErrorMapper.format(e, fallback: '检索课程失败');
      });
    } catch (e) {
      if (!mounted || currentGen != _courseSearchGen) return;
      setState(() {
        _isLoading = false;
        _error = GovernanceApiErrorMapper.format(e, fallback: '检索课程失败');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

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
        children: [
          Container(
            margin: const EdgeInsets.only(top: 10, bottom: 6),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.grey.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: Row(
              children: [
                Text(
                  widget.title,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.bold),
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
          Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: TextField(
              controller: _ctrl,
              decoration: InputDecoration(
                hintText: '输入课程名称或关键字搜索...',
                prefixIcon: const Icon(Icons.search, size: 20),
                isDense: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
              ),
              onChanged: _onQueryChanged,
            ),
          ),
          Expanded(
            child: _isLoading && _courses.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : _error != null && _courses.isEmpty
                    ? Center(child: Text(_error!))
                    : _courses.isEmpty
                        ? const Center(child: Text('未找到匹配的标准学科/课程'))
                        : ListView.separated(
                            padding: const EdgeInsets.symmetric(
                                horizontal: AppSpacing.md, vertical: 4),
                            itemCount: _courses.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 6),
                            itemBuilder: (ctx, idx) {
                              final c = _courses[idx];
                              return Card(
                                margin: EdgeInsets.zero,
                                color: isDark
                                    ? const Color(0xFF1E293B)
                                    : Colors.white,
                                shape: RoundedRectangleBorder(
                                  borderRadius:
                                      BorderRadius.circular(AppRadius.md),
                                  side: BorderSide(
                                    color: isDark
                                        ? Colors.white12
                                        : AppColors.borderNormalLight,
                                  ),
                                ),
                                child: ListTile(
                                  title: Text(
                                    c.name,
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      decoration: c.isMerged
                                          ? TextDecoration.lineThrough
                                          : null,
                                    ),
                                  ),
                                  subtitle: Text(
                                    '#${c.id} · ${c.teacherCount} 位授课教师 · ${c.ratingCount} 条评价',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: isDark
                                          ? Colors.white60
                                          : Colors.black54,
                                    ),
                                  ),
                                  trailing: c.isMerged
                                      ? Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 6, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: Colors.red
                                                .withValues(alpha: 0.15),
                                            borderRadius:
                                                BorderRadius.circular(4),
                                          ),
                                          child: Text(
                                            '已归并至 #${c.mergedIntoId}',
                                            style: const TextStyle(
                                                fontSize: 11,
                                                color: Colors.red),
                                          ),
                                        )
                                      : const Icon(Icons.chevron_right),
                                  onTap: c.isMerged
                                      ? () {
                                          ScaffoldMessenger.of(context)
                                              .showSnackBar(
                                            SnackBar(
                                              content: Text(
                                                  '该课程已合并至 #${c.mergedIntoId}，不能再作为合并目标'),
                                            ),
                                          );
                                        }
                                      : () {
                                          Navigator.pop(context);
                                          widget.onSelected(c);
                                        },
                                ),
                              );
                            },
                          ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// 别名选择组件
// ============================================================================

List<AliasTargetItem> _parseAliasTargets(dynamic data) {
  final raw = switch (data) {
    List() => data,
    Map() => data['items'] ?? data['data'] ?? data['list'],
    _ => null,
  };
  if (raw is! List) return const [];
  return raw
      .whereType<Map<String, dynamic>>()
      .map(AliasTargetItem.fromJson)
      .toList();
}

class _AliasTargetPicker extends StatefulWidget {
  const _AliasTargetPicker({
    required this.label,
    required this.hint,
    required this.targetType,
    required this.selected,
    required this.onSelected,
  });

  final String label;
  final String hint;
  final String targetType;
  final AliasTargetItem? selected;
  final ValueChanged<AliasTargetItem> onSelected;

  @override
  State<_AliasTargetPicker> createState() => _AliasTargetPickerState();
}

class _AliasTargetPickerState extends State<_AliasTargetPicker> {
  final TextEditingController _controller = TextEditingController();
  Timer? _debounce;
  int _targetSearchGen = 0;
  CancelToken? _targetCancelToken;
  List<AliasTargetItem> _options = const [];
  bool _isLoading = false;
  String? _errorMessage;
  bool _showOptions = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.selected == null) {
        _search('');
      }
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _targetCancelToken?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted) {
        _search(value);
      }
    });
  }

  Future<void> _search(String rawQuery) async {
    final query = rawQuery.trim();
    _targetCancelToken?.cancel();
    _targetCancelToken = CancelToken();
    final cancelToken = _targetCancelToken;
    final currentGen = ++_targetSearchGen;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _showOptions = true;
    });
    try {
      final dio = context.read<AuthProvider>().dio;
      final response = await dio.get(
        '/admin/teacher-governance/alias-targets',
        queryParameters: <String, dynamic>{
          'type': widget.targetType,
          if (query.isNotEmpty) 'q': query,
        },
        cancelToken: cancelToken,
      );
      if (!mounted || currentGen != _targetSearchGen) return;
      setState(() {
        _options = _parseAliasTargets(response.data);
        _isLoading = false;
      });
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) return;
      if (!mounted || currentGen != _targetSearchGen) return;
      setState(() {
        _options = const [];
        _isLoading = false;
        _errorMessage = GovernanceApiErrorMapper.format(e, fallback: '搜索失败');
      });
    } catch (e) {
      if (!mounted || currentGen != _targetSearchGen) return;
      setState(() {
        _options = const [];
        _isLoading = false;
        _errorMessage = GovernanceApiErrorMapper.format(e, fallback: '搜索失败');
      });
    }
  }

  void _select(AliasTargetItem item) {
    FocusScope.of(context).unfocus();
    setState(() {
      _showOptions = false;
      _options = const [];
      _controller.clear();
    });
    widget.onSelected(item);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selected = widget.selected;

    if (selected != null) {
      return InputDecorator(
        decoration: InputDecoration(
          labelText: widget.label,
          border: const OutlineInputBorder(),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                selected.label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium,
              ),
            ),
            SizedBox(
              width: 44,
              height: 44,
              child: IconButton(
                tooltip: '清空选择',
                padding: EdgeInsets.zero,
                icon: const Icon(Icons.close, size: 20),
                onPressed: () =>
                    _select(const AliasTargetItem(id: 0, name: '')),
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _controller,
          onChanged: _onQueryChanged,
          onTap: () {
            if (!_showOptions) {
              _search(_controller.text);
            }
          },
          decoration: InputDecoration(
            labelText: widget.label,
            hintText: widget.hint,
            border: const OutlineInputBorder(),
            prefixIcon: const Icon(Icons.search, size: 20),
            suffixIcon: _isLoading
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : null,
          ),
        ),
        if (_errorMessage != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              _errorMessage!,
              style: TextStyle(
                fontSize: 12,
                color: theme.colorScheme.error,
              ),
            ),
          ),
        if (_showOptions)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: _buildOptions(theme),
          ),
      ],
    );
  }

  Widget _buildOptions(ThemeData theme) {
    if (_options.isEmpty) {
      return Text(
        _isLoading ? '搜索中…' : '没有匹配的目标，请换关键词',
        style: TextStyle(
          fontSize: 12,
          color: theme.textTheme.bodySmall?.color,
        ),
      );
    }
    return Container(
      constraints: const BoxConstraints(maxHeight: 200),
      decoration: BoxDecoration(
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: ListView.builder(
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        itemCount: _options.length,
        itemBuilder: (context, index) {
          final item = _options[index];
          return InkWell(
            onTap: () => _select(item),
            child: Container(
              constraints: const BoxConstraints(minHeight: 44),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              alignment: Alignment.centerLeft,
              child: Text(
                '#${item.id}  ${item.label}',
                style: theme.textTheme.bodyMedium,
              ),
            ),
          );
        },
      ),
    );
  }
}
