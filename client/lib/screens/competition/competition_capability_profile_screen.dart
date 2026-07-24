import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../../models/competition_capability_profile.dart';
import '../../models/competition_preference.dart';
import '../../utils/app_feedback.dart';
import '../../widgets/competition/competition_ui_tokens.dart';

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
  bool _loading = true;
  bool _savingAccess = false;
  String? _error;
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
        _loading = true;
        _savingAccess = false;
        _error = null;
      });
      _load();
    }
  }

  Future<void> _load() async {
    final serial = ++_loadSerial;
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final responses = await Future.wait([
        widget.dio.get('/user/competition-capability-profile'),
        widget.dio.get('/user/competition-capability-profile/ai-access'),
      ]);
      if (!mounted || serial != _loadSerial) return;
      setState(() {
        _profile = CompetitionCapabilityProfile.fromJson(
          Map<String, dynamic>.from(responses[0].data as Map),
        );
        _aiAccess = CompetitionCapabilityAIAccess.fromJson(
          Map<String, dynamic>.from(responses[1].data as Map),
        );
        _loading = false;
      });
    } catch (error) {
      if (!mounted || serial != _loadSerial) return;
      setState(() {
        _loading = false;
        _error = error is DioException
            ? AppFeedback.dioErrorMessage(error, fallback: '能力画像加载失败')
            : '能力画像数据解析失败';
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
        enabled ? '已允�?AI 使用能力画像' : '已关�?AI 画像授权',
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
    final background = CompetitionUiTokens.pageBg(isDark);
    return Scaffold(
      backgroundColor: background,
      appBar: AppBar(
        backgroundColor: background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        title: const Text(
          '我的能力画像',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
      ),
      body: _buildBody(isDark),
    );
  }

  Widget _buildBody(bool isDark) {
    if (_loading) {
      return Center(
        child: CircularProgressIndicator(
          color: CompetitionUiTokens.accent(isDark),
        ),
      );
    }
    if (_error != null || _profile == null || _aiAccess == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error ?? '能力画像暂不可用', textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    final profile = _profile!;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
        children: [
          _countBand(profile, isDark),
          _sectionTitle('技�?, isDark),
          if (profile.skillSummary.isEmpty)
            _emptyLine('暂无可汇总的竞赛技�?, isDark)
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
          Divider(color: CompetitionUiTokens.borderColor(isDark), height: 1),
          SwitchListTile(
            key: const Key('competition-capability-ai-access'),
            contentPadding: const EdgeInsets.symmetric(vertical: 8),
            value: _aiAccess!.enabled,
            onChanged: _savingAccess ? null : _setAIAccess,
            activeTrackColor: CompetitionUiTokens.accent(isDark),
            title: const Text(
              '允许 AI 使用此画�?,
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            subtitle: const Text('仅包含竞赛目标和本页汇总，不包含证明材�?),
          ),
        ],
      ),
    );
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
          _countItem('已核验经�?, profile.verifiedAwardCount, isDark),
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
      if (item.selfReportedCount > 0) '${item.selfReportedCount}项本人填�?,
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
        .join('�?);
    final values = <(String, String)>[
      (
        '关注方向',
        profile.directionTags.isEmpty ? '未设�? : profile.directionTags.join('�?),
      ),
      ('偏好角色', roleLabels.isEmpty ? '未设�? : roleLabels),
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
