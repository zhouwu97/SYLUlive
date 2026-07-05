import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/competition.dart';
import '../../providers/auth_provider.dart';
import '../../utils/app_feedback.dart';
import '../../widgets/competition/competition_status_helper.dart';
import '../../widgets/competition/competition_ui_tokens.dart';
import 'competition_center_screen.dart';

class CompetitionCalendarItemDetailScreen extends StatefulWidget {
  final Map<String, dynamic> item;
  final List<CompetitionCategory> categories;

  const CompetitionCalendarItemDetailScreen({
    super.key,
    required this.item,
    required this.categories,
  });

  @override
  State<CompetitionCalendarItemDetailScreen> createState() =>
      _CompetitionCalendarItemDetailScreenState();
}

class _CompetitionCalendarItemDetailScreenState
    extends State<CompetitionCalendarItemDetailScreen> {
  late Map<String, dynamic> _item;

  @override
  void initState() {
    super.initState();
    _item = Map.from(widget.item);
  }

  Future<void> _openEditor() async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => CompetitionCalendarItemEditorScreen(
          item: _item,
          categories: widget.categories,
        ),
      ),
    );

    if (changed == true && mounted) {
      // Re-fetch or we just pop and let parent refresh. The easiest way is pop with true, 
      // but if we want to stay on detail page, we would need to fetch the updated item here.
      // But since there's no single item fetch API provided, we should just pop(true).
      Navigator.pop(context, true);
    }
  }

  Future<void> _archiveItem() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('归档比赛'),
        content: Text('确定归档「${_item['title'] ?? '未命名比赛'}」吗？归档后将移至已结束分组。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('归档'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    
    // Construct data like original
    final data = Map<String, dynamic>.from(_item);
    data['plan_status'] = 'archived';

    try {
      await context
          .read<AuthProvider>()
          .dio
          .put('/user/competition-calendar/items/${_item['id']}', data: data);
      if (!mounted) return;
      AppFeedback.showSnackBar(context, '已归档比赛');
      Navigator.pop(context, true);
    } on DioException catch (e) {
      if (!mounted) return;
      AppFeedback.showSnackBar(
        context,
        AppFeedback.dioErrorMessage(e, fallback: '归档失败'),
        isError: true,
      );
    }
  }

  Future<void> _deleteItem() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除比赛'),
        content: Text('确定从我的计划删除「${_item['title'] ?? '未命名比赛'}」吗？'),
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
      await dio.delete('/user/competition-calendar/items/${_item['id']}');
      if (!mounted) return;
      AppFeedback.showSnackBar(context, '已删除比赛');
      Navigator.pop(context, true);
    } on DioException catch (e) {
      if (!mounted) return;
      AppFeedback.showSnackBar(
        context,
        AppFeedback.dioErrorMessage(e, fallback: '删除失败'),
        isError: true,
      );
    }
  }

  String _calendarPlanStatus() {
    final value = '${_item['plan_status'] ?? ''}'.trim();
    return value.isEmpty ? 'watching' : value;
  }

  String _calendarTimeStatus() {
    final value = '${_item['time_status'] ?? ''}'.trim();
    if (value.isNotEmpty) return value;
    if (_item['registration_end'] != null && _item['registration_end'].toString().isNotEmpty) {
      return 'confirmed';
    }
    final text = '${_item['registration_time_text'] ?? ''} ${_item['event_time_text'] ?? ''}';
    if (text.contains('预计') || text.contains('暂定') || text.contains('计划')) {
      return 'estimated';
    }
    if (text.contains('往年') || text.contains('历年') || text.contains('通常')) {
      return 'historical';
    }
    return 'pending';
  }

  String _planStatusLabel(String value) {
    switch (value) {
      case 'preparing': return '准备中';
      case 'registered': return '已报名';
      case 'submitted': return '已提交';
      case 'finished': return '已结束';
      case 'archived': return '已归档';
      default: return '关注中';
    }
  }

  String _timeStatusLabel(String value) {
    switch (value) {
      case 'confirmed': return '时间已确认';
      case 'estimated': return '预计时间';
      case 'historical': return '参考往届';
      case 'pending': return '待通知';
      default: return '待通知';
    }
  }

  Widget _buildSection(String title, List<Widget> children, bool isDark) {
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
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    );
  }

  Widget _buildRow(String label, String value, bool isDark) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 70,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                color: CompetitionUiTokens.subColor(isDark),
              ),
            ),
          ),
          Expanded(
            child: Text(
              value.isEmpty ? '暂无' : value,
              style: TextStyle(
                fontSize: 13,
                color: CompetitionUiTokens.titleColor(isDark),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final pageBg = CompetitionUiTokens.pageBg(isDark);
    final titleColor = CompetitionUiTokens.titleColor(isDark);

    final title = '${_item['title'] ?? '未命名比赛'}';
    final summary = '${_item['summary'] ?? ''}';
    final description = '${_item['description'] ?? ''}';

    final regEnd = '${_item['registration_end'] ?? ''}';
    final regText = '${_item['registration_time_text'] ?? ''}';
    final regDisplay = regEnd.isNotEmpty ? regEnd : (regText.isNotEmpty ? regText : '原表未提供报名时间');

    final evStart = '${_item['event_start'] ?? ''}';
    final evText = '${_item['event_time_text'] ?? ''}';
    final evDisplay = evStart.isNotEmpty ? evStart : (evText.isNotEmpty ? evText : '原表未提供比赛时间');

    final source = competitionSourceLabel('${_item['source_type'] ?? ''}');
    final planStatus = _planStatusLabel(_calendarPlanStatus());
    final timeStatus = _timeStatusLabel(_calendarTimeStatus());
    final recommendation = '${_item['recommendation_level'] ?? '未知'}';
    final recognition = competitionRecognitionLabel('${_item['school_recognition_status'] ?? ''}');
    final level = '${_item['competition_level'] ?? _item['level'] ?? '未知'}';

    final location = '${_item['location'] ?? ''}';
    final isOnline = _item['is_online'] == true;
    final officialUrl = '${_item['official_url'] ?? ''}';
    final noticeUrl = '${_item['notice_url'] ?? ''}';

    return Scaffold(
      backgroundColor: pageBg,
      appBar: AppBar(
        backgroundColor: pageBg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        foregroundColor: titleColor,
        centerTitle: true,
        title: Text(
          '比赛详情',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w700,
            color: titleColor,
          ),
        ),
        actions: [
          PopupMenuButton<String>(
            icon: Icon(Icons.more_horiz_rounded, color: titleColor),
            onSelected: (value) {
              if (value == 'edit') _openEditor();
              if (value == 'archive') _archiveItem();
              if (value == 'delete') _deleteItem();
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'edit',
                child: Text('编辑比赛'),
              ),
              if (_calendarPlanStatus() != 'archived')
                const PopupMenuItem(
                  value: 'archive',
                  child: Text('归档'),
                ),
              const PopupMenuItem(
                value: 'delete',
                child: Text('删除', style: TextStyle(color: Colors.redAccent)),
              ),
            ],
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 28),
        children: [
          // Hero
          Container(
            margin: const EdgeInsets.only(bottom: 16),
            padding: const EdgeInsets.all(16),
            decoration: CompetitionUiTokens.cardDecoration(isDark),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                    color: titleColor,
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    _buildPill(planStatus, CompetitionUiTokens.warningColor(isDark)),
                    _buildPill(timeStatus, CompetitionUiTokens.accent(isDark)),
                    _buildPill(source, CompetitionUiTokens.subColor(isDark)),
                    if (recommendation.isNotEmpty && recommendation != '未知')
                      _buildPill('$recommendation推荐', CompetitionUiTokens.upcomingColor(isDark)),
                  ],
                ),
              ],
            ),
          ),

          // Time
          _buildSection('时间安排', [
            _buildRow('报名安排', regDisplay, isDark),
            _buildRow('比赛时间', evDisplay, isDark),
            _buildRow('举办地点', isOnline ? '线上比赛' : (location.isEmpty ? '未提供' : location), isDark),
          ], isDark),

          // Desc
          _buildSection('比赛说明', [
            if (summary.isNotEmpty) ...[
              Text(
                summary,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: titleColor,
                ),
              ),
              const SizedBox(height: 8),
            ],
            Text(
              description.isEmpty ? '暂无详细说明' : description,
              style: TextStyle(
                fontSize: 14,
                height: 1.5,
                color: CompetitionUiTokens.subColor(isDark),
              ),
            ),
          ], isDark),

          // Recognition
          _buildSection('推荐与认定', [
            _buildRow('推荐程度', recommendation, isDark),
            _buildRow('学校认定', recognition, isDark),
            _buildRow('竞赛级别', level, isDark),
          ], isDark),

          // Source
          _buildSection('来源与链接', [
            _buildRow('数据来源', source, isDark),
            _buildRow('官网链接', officialUrl.isEmpty ? '暂无' : officialUrl, isDark),
            _buildRow('通知链接', noticeUrl.isEmpty ? '暂无' : noticeUrl, isDark),
          ], isDark),

          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _openEditor,
            icon: const Icon(Icons.edit_outlined, size: 18),
            label: const Text('编辑比赛'),
            style: FilledButton.styleFrom(
              backgroundColor: CompetitionUiTokens.accent(isDark),
              minimumSize: const Size.fromHeight(50),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPill(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(CompetitionUiTokens.chipRadius),
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
}
