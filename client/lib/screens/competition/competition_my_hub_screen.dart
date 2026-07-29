import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../../models/competition_capability_profile.dart';
import '../../models/competition_dashboard_summary.dart';
import '../../models/competition_preference.dart';
import '../../utils/app_feedback.dart';
import '../../widgets/competition/competition_page_scaffold.dart';
import '../../widgets/competition/competition_profile_hub_card.dart';
import '../../widgets/competition/competition_ui_tokens.dart';
import 'competition_award_screen.dart';
import 'competition_capability_profile_screen.dart';
import 'competition_preference_screen.dart';

class CompetitionMyHubScreen extends StatefulWidget {
  final Dio dio;
  final Object accountKey;

  const CompetitionMyHubScreen({
    super.key,
    required this.dio,
    required this.accountKey,
  });

  @override
  State<CompetitionMyHubScreen> createState() => _CompetitionMyHubScreenState();
}

class _CompetitionMyHubScreenState extends State<CompetitionMyHubScreen> {
  CompetitionDashboardSummary? _dashboard;
  CompetitionCapabilityProfile? _profile;
  CompetitionCapabilityAIAccess? _aiAccess;
  bool _dashboardLoading = true;
  bool _profileLoading = true;
  bool _accessLoading = true;
  bool _savingAccess = false;
  String? _dashboardError;
  String? _profileError;
  String? _accessError;
  int _loadSerial = 0;

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  @override
  void didUpdateWidget(covariant CompetitionMyHubScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.accountKey != widget.accountKey ||
        oldWidget.dio != widget.dio) {
      _loadSerial++;
      _dashboard = null;
      _profile = null;
      _aiAccess = null;
      _loadAll();
    }
  }

  Future<void> _loadAll() async {
    await Future.wait([_loadDashboard(), _loadProfile(), _loadAIAccess()]);
  }

  Future<void> _loadDashboard() async {
    final serial = ++_loadSerial;
    setState(() {
      _dashboardLoading = true;
      _dashboardError = null;
    });
    try {
      final response = await widget.dio.get('/user/competitions/dashboard');
      if (!mounted || serial != _loadSerial) return;
      setState(() {
        _dashboard = CompetitionDashboardSummary.fromJson(
          Map<String, dynamic>.from(response.data as Map),
        );
        _dashboardLoading = false;
      });
    } catch (error) {
      if (!mounted || serial != _loadSerial) return;
      setState(() {
        _dashboardLoading = false;
        _dashboardError = error is DioException
            ? AppFeedback.dioErrorMessage(error, fallback: '竞赛档案摘要加载失败')
            : '竞赛档案摘要解析失败';
      });
    }
  }

  Future<void> _loadProfile() async {
    final account = widget.accountKey;
    setState(() {
      _profileLoading = true;
      _profileError = null;
    });
    try {
      final response =
          await widget.dio.get('/user/competition-capability-profile');
      if (!mounted || account != widget.accountKey) return;
      setState(() {
        _profile = CompetitionCapabilityProfile.fromJson(
          Map<String, dynamic>.from(response.data as Map),
        );
        _profileLoading = false;
      });
    } catch (error) {
      if (!mounted || account != widget.accountKey) return;
      setState(() {
        _profileLoading = false;
        _profileError = error is DioException
            ? AppFeedback.dioErrorMessage(error, fallback: '能力画像摘要加载失败')
            : '能力画像摘要解析失败';
      });
    }
  }

  Future<void> _loadAIAccess() async {
    final account = widget.accountKey;
    setState(() {
      _accessLoading = true;
      _accessError = null;
    });
    try {
      final response = await widget.dio
          .get('/user/competition-capability-profile/ai-access');
      if (!mounted || account != widget.accountKey) return;
      setState(() {
        _aiAccess = CompetitionCapabilityAIAccess.fromJson(
          Map<String, dynamic>.from(response.data as Map),
        );
        _accessLoading = false;
      });
    } catch (error) {
      if (!mounted || account != widget.accountKey) return;
      setState(() {
        _accessLoading = false;
        _accessError = error is DioException
            ? AppFeedback.dioErrorMessage(error, fallback: 'AI 授权状态读取失败')
            : 'AI 授权状态解析失败';
      });
    }
  }

  Future<void> _setAIAccess(bool enabled) async {
    if (_savingAccess) return;
    setState(() => _savingAccess = true);
    try {
      final response = await widget.dio.put(
        '/user/competition-capability-profile/ai-access',
        data: {'enabled': enabled},
      );
      if (!mounted) return;
      setState(() {
        _aiAccess = CompetitionCapabilityAIAccess.fromJson(
          Map<String, dynamic>.from(response.data as Map),
        );
        _accessError = null;
      });
      AppFeedback.showSnackBar(
        context,
        enabled ? '已允许 AI 使用竞赛画像' : '已关闭 AI 竞赛画像授权',
      );
    } catch (error) {
      if (!mounted) return;
      AppFeedback.showSnackBar(
        context,
        error is DioException
            ? AppFeedback.dioErrorMessage(error, fallback: '授权设置失败')
            : '授权设置失败',
        isError: true,
      );
    } finally {
      if (mounted) setState(() => _savingAccess = false);
    }
  }

  Future<void> _openPreference() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CompetitionPreferenceScreen(
          dio: widget.dio,
          accountKey: widget.accountKey,
        ),
      ),
    );
    if (mounted) {
      await Future.wait([_loadDashboard(), _loadProfile()]);
    }
  }

  Future<void> _openAwards() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CompetitionAwardScreen(
          dio: widget.dio,
          accountKey: widget.accountKey,
        ),
      ),
    );
    if (mounted) {
      await Future.wait([_loadDashboard(), _loadProfile()]);
    }
  }

  Future<void> _openProfile() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CompetitionCapabilityProfileScreen(
          dio: widget.dio,
          accountKey: widget.accountKey,
        ),
      ),
    );
    if (mounted) {
      await Future.wait([_loadDashboard(), _loadAIAccess()]);
    }
  }

  @override
  Widget build(BuildContext context) {
    return CompetitionPageScaffold(
      title: '我的竞赛',
      body: RefreshIndicator(
        onRefresh: _loadAll,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
          children: [
            if (_dashboardError != null && _dashboard == null)
              _errorBanner(_dashboardError!, _loadDashboard),
            CompetitionProfileHubCard(items: _hubItems()),
            const SizedBox(height: 14),
            _aiAccessCard(),
          ],
        ),
      ),
    );
  }

  List<CompetitionProfileHubItem> _hubItems() {
    final dashboard = _dashboard;
    final profile = _profile;
    return [
      CompetitionProfileHubItem(
        icon: Icons.flag_outlined,
        title: '竞赛目标',
        status: _dashboardLoading && dashboard == null
            ? '读取中'
            : dashboard?.preferenceConfigured == true
                ? '已设置'
                : '待完善',
        subtitle: _preferenceSubtitle(dashboard),
        onTap: _openPreference,
      ),
      CompetitionProfileHubItem(
        icon: Icons.workspace_premium_outlined,
        title: '竞赛经历',
        status: _dashboardLoading && dashboard == null
            ? '读取中'
            : '${dashboard?.awardTotal ?? 0}段',
        subtitle: _awardSubtitle(dashboard),
        onTap: _openAwards,
      ),
      CompetitionProfileHubItem(
        icon: Icons.diamond_outlined,
        title: '能力画像',
        status: _profileLoading && profile == null
            ? '读取中'
            : dashboard?.capabilityReady == true
                ? '可查看'
                : '待生成',
        subtitle: _profileSubtitle(profile),
        onTap: _openProfile,
      ),
    ];
  }

  String _preferenceSubtitle(CompetitionDashboardSummary? value) {
    if (value == null) return _dashboardError ?? '正在读取竞赛目标';
    if (!value.preferenceConfigured) return '设置参赛方向、角色和可投入时间';
    final goal = competitionGoalLabels[value.primaryGoal] ?? value.primaryGoal;
    return [
      if (goal.isNotEmpty) goal,
      if (value.primaryDirection.isNotEmpty) value.primaryDirection,
      competitionWeeklyHourLabels[value.weeklyHours] ??
          '每周 ${value.weeklyHours} 小时',
    ].join(' · ');
  }

  String _awardSubtitle(CompetitionDashboardSummary? value) {
    if (value == null) return _dashboardError ?? '正在读取竞赛经历';
    if (value.awardTotal == 0) return '记录参赛、获奖和团队贡献';
    return [
      '${value.verifiedAwardCount}项已核验',
      '${value.selfReportedAwardCount}项本人填写',
      if (value.pendingAwardCount > 0) '${value.pendingAwardCount}项核验中',
      if (value.rejectedAwardCount > 0) '${value.rejectedAwardCount}项需修改',
    ].join(' · ');
  }

  String _profileSubtitle(CompetitionCapabilityProfile? value) {
    if (value == null) return _profileError ?? '正在汇总技能和角色';
    final roles = value.roleSummary
        .take(2)
        .map((item) => competitionRoleLabels[item.value] ?? item.value)
        .join('、');
    return [
      '${value.skillSummary.length}项技能',
      if (roles.isNotEmpty) '主要角色：$roles',
    ].join(' · ');
  }

  Widget _aiAccessCard() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 6, 8, 8),
      decoration: CompetitionUiTokens.cardDecoration(isDark),
      child: _accessError != null && _aiAccess == null
          ? ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('AI 授权状态读取失败'),
              subtitle: Text(
                _accessError!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: IconButton(
                tooltip: '重试',
                onPressed: _loadAIAccess,
                icon: const Icon(Icons.refresh_rounded),
              ),
            )
          : SwitchListTile(
              key: const Key('competition-hub-ai-access'),
              contentPadding: EdgeInsets.zero,
              value: _aiAccess?.enabled ?? false,
              onChanged: _accessLoading || _savingAccess ? null : _setAIAccess,
              title: const Text(
                '允许 AI 使用竞赛画像',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
              subtitle: const Text('只使用目标与结构化汇总，不读取证明材料'),
            ),
    );
  }

  Widget _errorBanner(String message, VoidCallback onRetry) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.only(left: 12),
      decoration: BoxDecoration(
        color: CompetitionUiTokens.warningColor(isDark).withValues(alpha: .10),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              message,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            tooltip: '重试',
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
    );
  }
}
