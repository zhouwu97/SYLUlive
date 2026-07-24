import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../models/competition.dart';
import '../../models/competition_award.dart';
import '../../models/competition_preference.dart';
import '../../utils/app_feedback.dart';
import '../../widgets/competition/competition_ui_tokens.dart';

class CompetitionAwardEditorScreen extends StatefulWidget {
  final Dio dio;
  final CompetitionAward? initial;

  const CompetitionAwardEditorScreen({
    super.key,
    required this.dio,
    this.initial,
  });

  @override
  State<CompetitionAwardEditorScreen> createState() =>
      _CompetitionAwardEditorScreenState();
}

class _CompetitionAwardEditorScreenState
    extends State<CompetitionAwardEditorScreen> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _trackController = TextEditingController();
  final _yearController = TextEditingController();
  final _awardController = TextEditingController();
  final _awardLevelController = TextEditingController();
  final _contributionController = TextEditingController();
  final Set<String> _skills = {};
  final List<int> _evidenceFileIds = [];
  bool _manualCompetition = true;
  int? _competitionEventId;
  String _stage = 'school';
  String _role = 'member';
  String _visibility = 'private';
  bool _saving = false;
  bool _uploading = false;
  bool _eventsLoading = true;
  List<CompetitionEvent> _events = const [];

  bool get _coreLocked {
    final status = widget.initial?.verificationStatus;
    return status == 'pending' || status == 'verified';
  }

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _manualCompetition = initial?.competitionEventId == null;
    _competitionEventId = initial?.competitionEventId;
    _titleController.text = initial?.competitionTitle ?? '';
    _trackController.text = initial?.trackName ?? '';
    _yearController.text = '${initial?.competitionYear ?? DateTime.now().year}';
    _awardController.text = initial?.awardName ?? '';
    _awardLevelController.text = initial?.awardLevel ?? '';
    _contributionController.text = initial?.contributionSummary ?? '';
    _stage = initial?.competitionStage ?? 'school';
    _role = initial?.role ?? 'member';
    _visibility = initial?.visibility ?? 'private';
    _skills.addAll(initial?.skillTags ?? const []);
    _evidenceFileIds.addAll(initial?.evidenceFileIds ?? const []);
    _loadEvents();
  }

  @override
  void dispose() {
    _titleController.dispose();
    _trackController.dispose();
    _yearController.dispose();
    _awardController.dispose();
    _awardLevelController.dispose();
    _contributionController.dispose();
    super.dispose();
  }

  Future<void> _loadEvents() async {
    try {
      final response = await widget.dio.get(
        '/competitions/events',
        queryParameters: {'page': 1, 'page_size': 50},
      );
      final data = Map<String, dynamic>.from(response.data as Map);
      final events = ((data['items'] as List?) ?? const [])
          .map((item) =>
              CompetitionEvent.fromJson(Map<String, dynamic>.from(item as Map)))
          .toList();
      if (!mounted) return;
      setState(() {
        _events = events;
        _eventsLoading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _eventsLoading = false);
    }
  }

  Future<void> _pickEvidence() async {
    if (_coreLocked || _uploading || _evidenceFileIds.length >= 6) return;
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: true,
      withData: true,
    );
    if (result == null) return;
    final files = result.files.take(6 - _evidenceFileIds.length).toList();
    setState(() => _uploading = true);
    try {
      for (final file in files) {
        final bytes = file.bytes;
        if (bytes == null) continue;
        final response = await widget.dio.post(
          '/user/competition-awards/evidence',
          data: FormData.fromMap({
            'file': MultipartFile.fromBytes(bytes, filename: file.name),
          }),
        );
        final id = response.data is Map
            ? (response.data['evidence_file_id'] as num?)?.toInt()
            : null;
        if (id != null && !_evidenceFileIds.contains(id)) {
          _evidenceFileIds.add(id);
        }
      }
      if (mounted) setState(() {});
    } catch (error) {
      if (mounted) {
        AppFeedback.showSnackBar(
          context,
          error is DioException
              ? AppFeedback.dioErrorMessage(error, fallback: '证明材料上传失败')
              : '证明材料上传失败',
          isError: true,
        );
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  void _toggleSkill(String value) {
    if (_coreLocked) return;
    setState(() {
      if (_skills.remove(value)) return;
      if (_skills.length >= 12) {
        AppFeedback.showSnackBar(
          context,
          '技能标签最多选择 12 个',
          isError: true,
        );
        return;
      }
      _skills.add(value);
    });
  }

  Future<void> _save() async {
    if (_saving || !_formKey.currentState!.validate()) return;
    if (!_manualCompetition && _competitionEventId == null) {
      AppFeedback.showSnackBar(
        context,
        '请选择目录赛事，或切换为手动填写',
        isError: true,
      );
      return;
    }
    final year = int.tryParse(_yearController.text.trim());
    if (year == null || year < 2000 || year > DateTime.now().year + 1) {
      AppFeedback.showSnackBar(
        context,
        '比赛年份应在 2000 到 ${DateTime.now().year + 1} 之间',
        isError: true,
      );
      return;
    }
    final award = CompetitionAward(
      id: widget.initial?.id ?? 0,
      competitionEventId: _manualCompetition ? null : _competitionEventId,
      competitionTitle: _titleController.text,
      trackName: _trackController.text,
      competitionYear: year,
      awardName: _awardController.text,
      awardLevel: _awardLevelController.text,
      competitionStage: _stage,
      role: _role,
      skillTags: _skills.toList(),
      contributionSummary: _contributionController.text,
      evidenceFileIds: List.of(_evidenceFileIds),
      visibility: _visibility,
    );
    setState(() => _saving = true);
    try {
      if (widget.initial == null) {
        await widget.dio
            .post('/user/competition-awards', data: award.toPayload());
      } else {
        await widget.dio.put('/user/competition-awards/${widget.initial!.id}',
            data: award.toPayload());
      }
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (mounted) {
        AppFeedback.showSnackBar(
          context,
          error is DioException
              ? AppFeedback.dioErrorMessage(error, fallback: '保存失败')
              : '保存失败',
          isError: true,
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(title: Text(widget.initial == null ? '添加竞赛经历' : '编辑竞赛经历')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 110),
          children: [
            if (widget.initial != null) _verificationBanner(isDark),
            _section(
              '比赛信息',
              isDark,
              Column(
                children: [
                  SizedBox(
                    width: double.infinity,
                    child: SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(value: false, label: Text('目录赛事')),
                        ButtonSegment(value: true, label: Text('手动填写')),
                      ],
                      selected: {_manualCompetition},
                      showSelectedIcon: false,
                      onSelectionChanged: _coreLocked
                          ? null
                          : (value) => setState(() {
                                _manualCompetition = value.first;
                                if (_manualCompetition) {
                                  _competitionEventId = null;
                                }
                              }),
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (_manualCompetition)
                    _textField(_titleController, '比赛名称',
                        maxLength: 200, enabled: !_coreLocked)
                  else
                    DropdownButtonFormField<int>(
                      key: const Key('competition-award-event'),
                      initialValue: _competitionEventId,
                      decoration: InputDecoration(
                        labelText: _eventsLoading ? '正在读取赛事目录' : '选择目录赛事',
                        border: const OutlineInputBorder(),
                      ),
                      items: [
                        if (_competitionEventId != null &&
                            !_events.any(
                              (event) => event.id == _competitionEventId,
                            ))
                          DropdownMenuItem(
                            value: _competitionEventId,
                            child: Text(
                              '${widget.initial?.competitionTitle ?? '原关联赛事'}（目录中不可用）',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ..._events.map(
                          (event) => DropdownMenuItem(
                            value: event.id,
                            child: Text(
                              event.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ],
                      onChanged: _eventsLoading || _coreLocked
                          ? null
                          : (value) {
                              CompetitionEvent? event;
                              for (final item in _events) {
                                if (item.id == value) {
                                  event = item;
                                  break;
                                }
                              }
                              setState(() {
                                _competitionEventId = value;
                                if (event != null) {
                                  _titleController.text = event.title;
                                }
                              });
                            },
                    ),
                  const SizedBox(height: 12),
                  _textField(_trackController, '赛道（选填）',
                      maxLength: 100, enabled: !_coreLocked),
                  const SizedBox(height: 12),
                  _textField(_yearController, '比赛年份',
                      keyboardType: TextInputType.number,
                      enabled: !_coreLocked),
                ],
              ),
            ),
            _section(
              '结果与贡献',
              isDark,
              Column(
                children: [
                  _textField(_awardController, '奖项名称',
                      maxLength: 100, enabled: !_coreLocked),
                  const SizedBox(height: 12),
                  _textField(_awardLevelController, '奖项级别（选填）',
                      maxLength: 50, enabled: !_coreLocked),
                  const SizedBox(height: 12),
                  _dropdown('竞赛阶段', _stage, competitionAwardStageLabels,
                      (value) => setState(() => _stage = value),
                      enabled: !_coreLocked),
                  const SizedBox(height: 12),
                  _dropdown('承担角色', _role, competitionAwardRoleLabels,
                      (value) => setState(() => _role = value),
                      enabled: !_coreLocked),
                  const SizedBox(height: 12),
                  _textField(_contributionController, '贡献描述（选填）',
                      maxLength: 1000, maxLines: 4, enabled: !_coreLocked),
                ],
              ),
            ),
            _section(
              '技能标签',
              isDark,
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: competitionSkillOptions
                    .map((skill) => FilterChip(
                          label: Text(skill),
                          selected: _skills.contains(skill),
                          onSelected:
                              _coreLocked ? null : (_) => _toggleSkill(skill),
                        ))
                    .toList(),
              ),
            ),
            _section(
              '证明材料',
              isDark,
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  OutlinedButton.icon(
                    key: const Key('competition-award-evidence'),
                    onPressed: _coreLocked ||
                            _uploading ||
                            _evidenceFileIds.length >= 6
                        ? null
                        : _pickEvidence,
                    icon: _uploading
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.upload_file_outlined),
                    label: Text(_uploading ? '上传中' : '添加图片材料'),
                  ),
                  if (_evidenceFileIds.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: List.generate(
                        _evidenceFileIds.length,
                        (index) => InputChip(
                          label: Text('材料 ${index + 1}'),
                          onDeleted: _coreLocked
                              ? null
                              : () => setState(
                                  () => _evidenceFileIds.removeAt(index)),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 6),
                  Text('材料仅用于后续平台核验，不会自动公开。最多 6 份。',
                      style: TextStyle(
                          fontSize: 12,
                          color: CompetitionUiTokens.subColor(isDark))),
                ],
              ),
            ),
            _section(
              '可见范围',
              isDark,
              Column(
                children: [
                  _dropdown(
                      '可见范围',
                      _visibility,
                      competitionAwardVisibilityLabels,
                      (value) => setState(() => _visibility = value)),
                  const SizedBox(height: 8),
                  Text('当前版本仅保存此设置，暂不接入公开主页或组队推荐。',
                      style: TextStyle(
                          fontSize: 12,
                          color: CompetitionUiTokens.subColor(isDark))),
                ],
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
          child: SizedBox(
            height: 46,
            child: FilledButton.icon(
              key: const Key('competition-award-save'),
              onPressed: _saving || _uploading ? null : _save,
              icon: _saving
                  ? const SizedBox.square(
                      dimension: 17,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.save_outlined),
              label: Text(_saving ? '保存中' : '保存'),
            ),
          ),
        ),
      ),
    );
  }

  Widget _verificationBanner(bool isDark) {
    final status = competitionAwardStatusLabels[
            widget.initial?.verificationStatus ?? 'self_reported'] ??
        competitionAwardStatusLabels['self_reported']!;
    final locked = _coreLocked;
    return Container(
      key: const Key('competition-award-verification-banner'),
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.all(12),
      decoration: CompetitionUiTokens.cardDecoration(isDark),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.verified_user_outlined,
            size: 20,
            color: CompetitionUiTokens.accent(isDark),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              locked
                  ? '当前状态：$status。核心信息和证明材料暂不可修改，仅可调整可见范围。'
                  : widget.initial?.verificationStatus == 'rejected'
                      ? '当前状态：$status。可修改信息和材料，保存后再重新提交核验。'
                      : '当前状态：$status',
              style: TextStyle(
                fontSize: 13,
                height: 1.4,
                color: CompetitionUiTokens.subColor(isDark),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _section(String title, bool isDark, Widget child) => Padding(
        padding: const EdgeInsets.only(bottom: 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: CompetitionUiTokens.titleColor(isDark))),
            const SizedBox(height: 10),
            child,
          ],
        ),
      );

  TextFormField _textField(
    TextEditingController controller,
    String label, {
    int? maxLength,
    int maxLines = 1,
    TextInputType? keyboardType,
    bool enabled = true,
  }) =>
      TextFormField(
        controller: controller,
        maxLength: maxLength,
        maxLines: maxLines,
        keyboardType: keyboardType,
        enabled: enabled,
        decoration: InputDecoration(
            labelText: label, border: const OutlineInputBorder()),
        validator: (value) {
          if ((controller == _titleController && _manualCompetition) ||
              controller == _awardController ||
              controller == _yearController) {
            if ((value ?? '').trim().isEmpty) return '请填写$label';
          }
          return null;
        },
      );

  DropdownButtonFormField<String> _dropdown(String label, String value,
          Map<String, String> options, ValueChanged<String> onChanged,
          {bool enabled = true}) =>
      DropdownButtonFormField<String>(
        initialValue: value,
        decoration: InputDecoration(
            labelText: label, border: const OutlineInputBorder()),
        items: options.entries
            .map((entry) =>
                DropdownMenuItem(value: entry.key, child: Text(entry.value)))
            .toList(),
        onChanged: enabled
            ? (value) {
                if (value != null) onChanged(value);
              }
            : null,
      );
}
