import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../../models/competition_preference.dart';
import '../../utils/app_feedback.dart';
import '../../widgets/competition/competition_page_scaffold.dart';
import '../../widgets/competition/competition_ui_tokens.dart';

class CompetitionPreferenceScreen extends StatefulWidget {
  final Dio dio;
  final Object accountKey;

  const CompetitionPreferenceScreen({
    super.key,
    required this.dio,
    required this.accountKey,
  });

  @override
  State<CompetitionPreferenceScreen> createState() =>
      _CompetitionPreferenceScreenState();
}

class _CompetitionPreferenceScreenState
    extends State<CompetitionPreferenceScreen> {
  final _careerController = TextEditingController();
  final Set<String> _goals = {};
  final Set<String> _directions = {};
  final Set<String> _skills = {};
  final Set<String> _roles = {};
  int _weeklyHours = 0;
  bool _acceptLongTermTraining = false;
  String _experienceLevel = 'beginner';
  bool _loading = true;
  bool _saving = false;
  String? _error;
  int _loadSerial = 0;
  String _savedSignature = '';
  bool _applyingPreference = false;

  bool get _isDirty => !_loading && _savedSignature != _signature();

  @override
  void initState() {
    super.initState();
    _careerController.addListener(_onCareerChanged);
    _load();
  }

  @override
  void didUpdateWidget(covariant CompetitionPreferenceScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.accountKey != widget.accountKey ||
        oldWidget.dio != widget.dio) {
      _resetForAccountChange();
      _load();
    }
  }

  @override
  void dispose() {
    _careerController.removeListener(_onCareerChanged);
    _careerController.dispose();
    super.dispose();
  }

  void _onCareerChanged() {
    if (mounted && !_loading && !_applyingPreference) setState(() {});
  }

  String _signature() {
    String values(Iterable<String> source) {
      final sorted = source.toList()..sort();
      return sorted.join('\u0001');
    }

    return [
      values(_goals),
      values(_directions),
      values(_skills),
      values(_roles),
      '$_weeklyHours',
      '$_acceptLongTermTraining',
      _experienceLevel,
      _careerController.text.trim(),
    ].join('\u0002');
  }

  void _resetForAccountChange() {
    _loadSerial++;
    _goals.clear();
    _directions.clear();
    _skills.clear();
    _roles.clear();
    _careerController.clear();
    _weeklyHours = 0;
    _acceptLongTermTraining = false;
    _experienceLevel = 'beginner';
    _loading = true;
    _saving = false;
    _error = null;
    _savedSignature = '';
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
      final response = await widget.dio.get('/user/competition-preference');
      if (!mounted || serial != _loadSerial) {
        return;
      }
      final preference = CompetitionPreference.fromJson(
        Map<String, dynamic>.from(response.data as Map),
      );
      setState(() {
        _applyPreference(preference);
        _savedSignature = _signature();
        _loading = false;
      });
    } catch (error) {
      if (!mounted || serial != _loadSerial) return;
      setState(() {
        _loading = false;
        _error = error is DioException
            ? AppFeedback.dioErrorMessage(error, fallback: '竞赛目标加载失败')
            : '竞赛目标数据解析失败';
      });
    }
  }

  void _applyPreference(CompetitionPreference preference) {
    _applyingPreference = true;
    _goals
      ..clear()
      ..addAll(preference.goals);
    _directions
      ..clear()
      ..addAll(preference.directionTags);
    _skills
      ..clear()
      ..addAll(preference.skillTags);
    _roles
      ..clear()
      ..addAll(preference.preferredRoles);
    _weeklyHours =
        competitionWeeklyHourLabels.containsKey(preference.weeklyHours)
            ? preference.weeklyHours
            : 0;
    _acceptLongTermTraining = preference.acceptLongTermTraining;
    _experienceLevel =
        competitionExperienceLabels.containsKey(preference.experienceLevel)
            ? preference.experienceLevel
            : 'beginner';
    _careerController.text = preference.careerDirection;
    _applyingPreference = false;
  }

  void _toggle(Set<String> target, String value, int limit) {
    setState(() {
      if (!target.remove(value)) {
        if (target.length >= limit) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('最多选择 $limit 项')),
          );
          return;
        }
        target.add(value);
      }
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    FocusScope.of(context).unfocus();
    setState(() => _saving = true);
    final preference = CompetitionPreference(
      configured: true,
      goals: _goals.toList(),
      directionTags: _directions.toList(),
      skillTags: _skills.toList(),
      preferredRoles: _roles.toList(),
      weeklyHours: _weeklyHours,
      acceptLongTermTraining: _acceptLongTermTraining,
      careerDirection: _careerController.text,
      experienceLevel: _experienceLevel,
    );
    try {
      final response = await widget.dio.put(
        '/user/competition-preference',
        data: preference.toJson(),
      );
      if (!mounted) return;
      final saved = CompetitionPreference.fromJson(
        Map<String, dynamic>.from(response.data as Map),
      );
      setState(() {
        _applyPreference(saved);
        _savedSignature = _signature();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('竞赛目标已保存')),
      );
    } catch (error) {
      if (!mounted) return;
      final message = error is DioException
          ? AppFeedback.dioErrorMessage(error, fallback: '保存失败，请稍后重试')
          : '保存失败，请稍后重试';
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final background = CompetitionUiTokens.pageBg(isDark);
    return PopScope(
      canPop: !_isDirty,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop || !_isDirty) return;
        final leave = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('放弃未保存的修改？'),
            content: const Text('返回后，本次修改不会保留。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('继续编辑'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('放弃修改'),
              ),
            ],
          ),
        );
        if (leave == true && context.mounted) {
          Navigator.of(context).pop();
        }
      },
      child: CompetitionPageScaffold(
        title: '我的竞赛目标',
        body: _loading
            ? Center(
                child: CircularProgressIndicator(
                    color: CompetitionUiTokens.accent(isDark)))
            : _error != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(_error!, textAlign: TextAlign.center),
                          const SizedBox(height: 12),
                          FilledButton.icon(
                            onPressed: _load,
                            icon: const Icon(Icons.refresh_rounded),
                            label: const Text('重试'),
                          ),
                        ],
                      ),
                    ),
                  )
                : Column(
                    children: [
                      Expanded(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _groupCard(
                                title: '参赛方向',
                                isDark: isDark,
                                children: [
                                  _section(
                                    title: '参加比赛主要为了什么',
                                    child: _chips(
                                      competitionGoalLabels,
                                      _goals,
                                      (value) => _toggle(_goals, value, 3),
                                      isDark,
                                    ),
                                    isDark: isDark,
                                  ),
                                  if (_goals.contains('graduation_gap'))
                                    _graduationDisclaimer(isDark),
                                  _section(
                                    title: '感兴趣的比赛方向',
                                    child: _plainChips(
                                      competitionDirectionOptions,
                                      _directions,
                                      (value) => _toggle(_directions, value, 8),
                                      isDark,
                                    ),
                                    isDark: isDark,
                                  ),
                                ],
                              ),
                              _groupCard(
                                title: '能力与角色',
                                isDark: isDark,
                                children: [
                                  _section(
                                    title: '技能',
                                    child: _plainChips(
                                      competitionSkillOptions,
                                      _skills,
                                      (value) => _toggle(_skills, value, 12),
                                      isDark,
                                    ),
                                    isDark: isDark,
                                  ),
                                  _section(
                                    title: '偏好角色',
                                    child: _chips(
                                      competitionRoleLabels,
                                      _roles,
                                      (value) => _toggle(_roles, value, 3),
                                      isDark,
                                    ),
                                    isDark: isDark,
                                  ),
                                  _section(
                                    title: '当前竞赛经验',
                                    subtitle: '仅用于偏好匹配，不作为获奖核验证据',
                                    child: _singleChoiceChips(
                                      competitionExperienceLabels,
                                      _experienceLevel,
                                      (value) => setState(
                                          () => _experienceLevel = value),
                                      isDark,
                                    ),
                                    isDark: isDark,
                                  ),
                                ],
                              ),
                              _groupCard(
                                title: '时间与规划',
                                isDark: isDark,
                                children: [
                                  _section(
                                    title: '每周投入时间',
                                    child: _singleChoiceChips(
                                      competitionWeeklyHourLabels,
                                      _weeklyHours,
                                      (value) =>
                                          setState(() => _weeklyHours = value),
                                      isDark,
                                    ),
                                    isDark: isDark,
                                  ),
                                  _section(
                                    title: '是否接受长期训练',
                                    child: SegmentedButton<bool>(
                                      segments: const [
                                        ButtonSegment(
                                            value: true, label: Text('接受')),
                                        ButtonSegment(
                                          value: false,
                                          label: Text('更偏好短期项目'),
                                        ),
                                      ],
                                      selected: {_acceptLongTermTraining},
                                      onSelectionChanged: (value) => setState(
                                        () => _acceptLongTermTraining =
                                            value.first,
                                      ),
                                      showSelectedIcon: false,
                                    ),
                                    isDark: isDark,
                                  ),
                                  _section(
                                    title: '职业方向（选填）',
                                    child: TextField(
                                      controller: _careerController,
                                      maxLength: 80,
                                      maxLines: 1,
                                      decoration: const InputDecoration(
                                        hintText: '例如：后端开发、机械设计、数据分析',
                                        border: OutlineInputBorder(),
                                      ),
                                    ),
                                    isDark: isDark,
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
        bottomNavigationBar: _loading || _error != null
            ? null
            : DecoratedBox(
                decoration: BoxDecoration(
                  color: background,
                  border: Border(
                    top: BorderSide(
                      color: CompetitionUiTokens.borderColor(isDark),
                    ),
                  ),
                ),
                child: SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                    child: SizedBox(
                      width: double.infinity,
                      height: 46,
                      child: FilledButton.icon(
                        key: const Key('competition-preference-save'),
                        onPressed: _saving || !_isDirty ? null : _save,
                        icon: _saving
                            ? const SizedBox.square(
                                dimension: 18,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.save_outlined),
                        label: Text(_saving ? '保存中' : '保存'),
                      ),
                    ),
                  ),
                ),
              ),
      ),
    );
  }

  Widget _groupCard({
    required String title,
    required bool isDark,
    required List<Widget> children,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 0),
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
          const SizedBox(height: 14),
          ...children,
        ],
      ),
    );
  }

  Widget _section({
    required String title,
    String? subtitle,
    required Widget child,
    required bool isDark,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: CompetitionUiTokens.titleColor(isDark))),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(subtitle,
                style: TextStyle(
                    fontSize: 12, color: CompetitionUiTokens.subColor(isDark))),
          ],
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }

  Widget _chips(
    Map<String, String> options,
    Set<String> selected,
    ValueChanged<String> onSelected,
    bool isDark,
  ) =>
      _plainChips(options.keys, selected, onSelected, isDark, labels: options);

  Widget _plainChips(
    Iterable<String> options,
    Set<String> selected,
    ValueChanged<String> onSelected,
    bool isDark, {
    Map<String, String>? labels,
  }) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: options.map((value) {
        final active = selected.contains(value);
        return FilterChip(
          label: Text(labels?[value] ?? value),
          selected: active,
          onSelected: (_) => onSelected(value),
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: const VisualDensity(vertical: -2),
          selectedColor: CompetitionUiTokens.accentSoft(isDark),
          checkmarkColor: CompetitionUiTokens.accent(isDark),
          side: BorderSide(
              color: active
                  ? CompetitionUiTokens.accent(isDark)
                  : CompetitionUiTokens.borderColor(isDark)),
        );
      }).toList(),
    );
  }

  Widget _singleChoiceChips<T>(
    Map<T, String> options,
    T selected,
    ValueChanged<T> onSelected,
    bool isDark,
  ) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: options.entries.map((entry) {
        return ChoiceChip(
          label: Text(entry.value),
          selected: selected == entry.key,
          onSelected: (_) => onSelected(entry.key),
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: const VisualDensity(vertical: -2),
          selectedColor: CompetitionUiTokens.accentSoft(isDark),
          side: BorderSide(
              color: selected == entry.key
                  ? CompetitionUiTokens.accent(isDark)
                  : CompetitionUiTokens.borderColor(isDark)),
        );
      }).toList(),
    );
  }

  Widget _graduationDisclaimer(bool isDark) {
    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: CompetitionUiTokens.warningColor(isDark).withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
            color: CompetitionUiTokens.warningColor(isDark)
                .withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline_rounded,
              size: 18, color: CompetitionUiTokens.warningColor(isDark)),
          const SizedBox(width: 8),
          const Expanded(child: Text('“毕业补齐”仅表示你的参赛目标，不代表比赛一定可以获得毕业学分。')),
        ],
      ),
    );
  }
}
