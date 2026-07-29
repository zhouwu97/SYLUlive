import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../../models/competition_capability_profile.dart';
import '../../models/competition_preference.dart';
import '../../utils/app_feedback.dart';
import '../../widgets/competition/competition_page_scaffold.dart';
import '../../widgets/competition/competition_ui_tokens.dart';
import 'competition_award_screen.dart';
import 'competition_preference_screen.dart';

class CompetitionCapabilityProfileScreen extends StatefulWidget {
  final Dio dio;
  final Object accountKey;

  const CompetitionCapabilityProfileScreen({
    super.key,
    required this.dio,
    required this.accountKey,
  });

  @override
  State<CompetitionCapabilityProfileScreen> createState() =>
      _CompetitionCapabilityProfileScreenState();
}

class _CompetitionCapabilityProfileScreenState
    extends State<CompetitionCapabilityProfileScreen> {
  CompetitionCapabilityProfile? _profile;
  CompetitionCapabilityAIAccess? _aiAccess;
  bool _profileLoading = true;
  bool _accessLoading = true;
  bool _savingAccess = false;
  String? _profileError;
  String? _accessError;
  int _loadSerial = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant CompetitionCapabilityProfileScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.accountKey != widget.accountKey ||
        oldWidget.dio != widget.dio) {
      setState(() {
        _profile = null;
        _aiAccess = null;
        _profileLoading = true;
        _accessLoading = true;
        _savingAccess = false;
        _profileError = null;
        _accessError = null;
      });
      _load();
    }
  }

  Future<void> _load() async {
    await Future.wait([_loadProfile(), _loadAIAccess()]);
  }

  Future<void> _loadProfile() async {
    final serial = ++_loadSerial;
    if (mounted) {
      setState(() {
        _profileLoading = true;
        _profileError = null;
      });
    }
    try {
      final response =
          await widget.dio.get('/user/competition-capability-profile');
      if (!mounted || serial != _loadSerial) return;
      setState(() {
        _profile = CompetitionCapabilityProfile.fromJson(
          Map<String, dynamic>.from(response.data as Map),
        );
        _profileLoading = false;
      });
    } catch (error) {
      if (!mounted || serial != _loadSerial) return;
      setState(() {
        _profileLoading = false;
        _profileError = error is DioException
            ? AppFeedback.dioErrorMessage(error, fallback: '能力画像加载失败')
            : '能力画像数据解析失败';
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
      });
      AppFeedback.showSnackBar(
        context,
        enabled ? '已允许 AI 使用能力画像' : '已关闭 AI 画像授权',
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

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return CompetitionPageScaffold(
      title: '我的能力画像',
      body: _buildBody(isDark),
    );
  }

  Widget _buildBody(bool isDark) {
    if (_profileLoading && _profile == null) {
      return Center(
        child: CircularProgressIndicator(
          color: CompetitionUiTokens.accent(isDark),
        ),
      );
    }
    if (_profileError != null || _profile == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _profileError ?? '能力画像暂不可用',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _loadProfile,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    final profile = _profile!;
    final ready = profile.preferenceConfigured ||
        profile.verifiedAwardCount + profile.selfReportedAwardCount > 0;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
        children: ready
            ? [
                _countBand(profile, isDark),
                _sectionTitle('技能', isDark),
                if (profile.skillSummary.isEmpty)
                  _emptyLine('暂无可汇总的竞赛技能', isDark)
                else
                  ...profile.skillSummary.map(
                    (item) => _summaryRow(item.value, item, isDark),
                  ),
                _sectionTitle('经历角色', isDark),
                if (profile.roleSummary.isEmpty)
                  _emptyLine('暂无可汇总的竞赛角色', isDark)
                else
                  ...profile.roleSummary.map(
                    (item) => _summaryRow(
                      competitionRoleLabels[item.value] ?? item.value,
                      item,
                      isDark,
                    ),
                  ),
                _sectionTitle('竞赛目标', isDark),
                _preferenceSummary(profile, isDark),
                const SizedBox(height: 16),
                _buildAIAccess(isDark),
              ]
            : [
                _emptyProfileCard(isDark),
              ],
      ),
    );
  }

  Widget _buildAIAccess(bool isDark) {
    return Container(
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: CompetitionUiTokens.borderColor(isDark)),
        ),
      ),
      child: _accessError != null && _aiAccess == null
          ? ListTile(
              contentPadding: const EdgeInsets.symmetric(vertical: 4),
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
              key: const Key('competition-capability-ai-access'),
              contentPadding: const EdgeInsets.symmetric(vertical: 8),
              value: _aiAccess?.enabled ?? false,
              onChanged: _savingAccess || _accessLoading || _aiAccess == null
                  ? null
                  : _setAIAccess,
              title: const Text(
                '允许 AI 使用此画像',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
              subtitle: const Text('仅包含竞赛目标和本页汇总，不包含证明材料'),
            ),
    );
  }

  Widget _emptyProfileCard(bool isDark) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 30, 20, 24),
      decoration: CompetitionUiTokens.cardDecoration(isDark),
      child: Column(
        children: [
          Icon(
            Icons.diamond_outlined,
            size: 40,
            color: CompetitionUiTokens.accent(isDark),
          ),
          const SizedBox(height: 14),
          Text(
            '还不能生成能力画像',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w800,
              color: CompetitionUiTokens.titleColor(isDark),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '设置竞赛目标或添加竞赛经历后，\n这里会汇总你的技能、角色和参赛方向。',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              height: 1.5,
              color: CompetitionUiTokens.subColor(isDark),
            ),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _openPreference,
                  child: const Text('设置竞赛目标'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  onPressed: _openAwards,
                  child: const Text('添加竞赛经历'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
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
    if (mounted) await _loadProfile();
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
    if (mounted) await _loadProfile();
  }

  Widget _countBand(CompetitionCapabilityProfile profile, bool isDark) {
    return Container(
      decoration: BoxDecoration(
        color: CompetitionUiTokens.cardBg(isDark),
        border: Border.all(color: CompetitionUiTokens.borderColor(isDark)),
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Row(
        children: [
          _countItem('已核验经历', profile.verifiedAwardCount, isDark),
          Container(
            width: 1,
            height: 38,
            color: CompetitionUiTokens.borderColor(isDark),
          ),
          _countItem('本人填写经历', profile.selfReportedAwardCount, isDark),
        ],
      ),
    );
  }

  Widget _countItem(String label, int value, bool isDark) {
    return Expanded(
      child: Column(
        children: [
          Text(
            '$value',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: CompetitionUiTokens.titleColor(isDark),
            ),
          ),
          const SizedBox(height: 3),
          Text(
            label,
            style: TextStyle(color: CompetitionUiTokens.subColor(isDark)),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String title, bool isDark) {
    return Padding(
      padding: const EdgeInsets.only(top: 22, bottom: 8),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w700,
          color: CompetitionUiTokens.titleColor(isDark),
        ),
      ),
    );
  }

  Widget _summaryRow(
    String label,
    CompetitionCapabilityCount item,
    bool isDark,
  ) {
    final counts = <String>[
      if (item.verifiedCount > 0) '${item.verifiedCount}项已核验',
      if (item.selfReportedCount > 0) '${item.selfReportedCount}项本人填写',
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(color: CompetitionUiTokens.titleColor(isDark)),
            ),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              counts.join(' · '),
              textAlign: TextAlign.end,
              style: TextStyle(
                fontSize: 13,
                color: CompetitionUiTokens.subColor(isDark),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _preferenceSummary(CompetitionCapabilityProfile profile, bool isDark) {
    if (!profile.preferenceConfigured) {
      return _emptyLine('尚未设置竞赛目标', isDark);
    }
    final roleLabels = profile.preferredRoles
        .map((role) => competitionRoleLabels[role] ?? role)
        .join('、');
    final values = <(String, String)>[
      (
        '关注方向',
        profile.directionTags.isEmpty ? '未设置' : profile.directionTags.join('、'),
      ),
      ('偏好角色', roleLabels.isEmpty ? '未设置' : roleLabels),
      ('每周投入', profile.weeklyHours == 0 ? '暂不确定' : '${profile.weeklyHours} 小时'),
      ('长期训练', profile.acceptLongTermTraining ? '可以接受' : '暂不考虑'),
    ];
    return Column(
      children: values
          .map(
            (item) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 76,
                    child: Text(
                      item.$1,
                      style: TextStyle(
                        color: CompetitionUiTokens.subColor(isDark),
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      item.$2,
                      style: TextStyle(
                        color: CompetitionUiTokens.titleColor(isDark),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          )
          .toList(),
    );
  }

  Widget _emptyLine(String text, bool isDark) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Text(
        text,
        style: TextStyle(color: CompetitionUiTokens.subColor(isDark)),
      ),
    );
  }
}
