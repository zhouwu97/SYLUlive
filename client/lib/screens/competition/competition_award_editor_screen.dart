import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../models/competition.dart';
import '../../models/competition_award.dart';
import '../../models/competition_preference.dart';
import '../../utils/app_feedback.dart';
import '../../widgets/competition/competition_page_scaffold.dart';
import '../../widgets/competition/competition_ui_tokens.dart';

class _EvidencePreviewItem {
  int? fileId;
  Uint8List? bytes;
  final String name;
  bool uploading;
  bool failed;

  _EvidencePreviewItem({
    this.fileId,
    this.bytes,
    required this.name,
    this.uploading = false,
  }) : failed = false;
}

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
  final List<_EvidencePreviewItem> _evidenceItems = [];
  bool _manualCompetition = true;
  int? _competitionEventId;
  String _stage = 'school';
  String _role = 'member';
  String _visibility = 'private';
  bool _saving = false;

  bool get _uploading => _evidenceItems.any((item) => item.uploading);

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
    for (final fileId in initial?.evidenceFileIds ?? const <int>[]) {
      final item = _EvidencePreviewItem(
        fileId: fileId,
        name: '材料 $fileId',
        uploading: true,
      );
      _evidenceItems.add(item);
      _loadEvidencePreview(item);
    }
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

  Future<void> _loadEvidencePreview(_EvidencePreviewItem item) async {
    final awardId = widget.initial?.id;
    final fileId = item.fileId;
    if (awardId == null || fileId == null) return;
    try {
      final response = await widget.dio.get(
        '/user/competition-awards/$awardId/evidence/$fileId',
        options: Options(responseType: ResponseType.bytes),
      );
      if (!mounted) return;
      setState(() {
        item.bytes = Uint8List.fromList(List<int>.from(response.data as List));
        item.uploading = false;
        item.failed = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          item.uploading = false;
          item.failed = true;
        });
      }
    }
  }

  Future<void> _pickEvidence() async {
    if (_coreLocked || _uploading || _evidenceItems.length >= 6) return;
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: true,
      withData: true,
    );
    if (result == null) return;
    final items = <_EvidencePreviewItem>[];
    for (final file in result.files.take(6 - _evidenceItems.length)) {
      if (file.bytes == null) continue;
      items.add(
        _EvidencePreviewItem(
          bytes: file.bytes,
          name: file.name,
          uploading: true,
        ),
      );
    }
    if (items.isEmpty) return;
    setState(() => _evidenceItems.addAll(items));
    for (final item in items) {
      await _uploadEvidenceItem(item);
    }
  }

  Future<void> _uploadEvidenceItem(_EvidencePreviewItem item) async {
    final bytes = item.bytes;
    if (bytes == null) return;
    setState(() {
      item.uploading = true;
      item.failed = false;
    });
    try {
      final response = await widget.dio.post(
        '/user/competition-awards/evidence',
        data: FormData.fromMap({
          'file': MultipartFile.fromBytes(bytes, filename: item.name),
        }),
      );
      final id = response.data is Map
          ? (response.data['evidence_file_id'] as num?)?.toInt()
          : null;
      if (id == null) throw const FormatException('缺少材料编号');
      if (!mounted) return;
      setState(() {
        item.fileId = id;
        item.uploading = false;
        item.failed = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        item.uploading = false;
        item.failed = true;
      });
      AppFeedback.showSnackBar(
        context,
        error is DioException
            ? AppFeedback.dioErrorMessage(error, fallback: '证明材料上传失败')
            : '证明材料上传失败',
        isError: true,
      );
    }
  }

  Future<void> _selectCompetitionEvent() async {
    if (_coreLocked) return;
    final selected = await Navigator.of(context).push<CompetitionEvent>(
      MaterialPageRoute(
        builder: (_) => _CompetitionEventPickerScreen(
          dio: widget.dio,
          initialEventId: _competitionEventId,
          initialTitle: _titleController.text,
        ),
      ),
    );
    if (selected == null || !mounted) return;
    setState(() {
      _competitionEventId = selected.id;
      _titleController.text = selected.title;
    });
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
      evidenceFileIds: _evidenceItems
          .map((item) => item.fileId)
          .whereType<int>()
          .toList(growable: false),
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
    return CompetitionPageScaffold(
      title: widget.initial == null
          ? '添加竞赛经历'
          : _coreLocked
              ? '查看竞赛经历'
              : '编辑竞赛经历',
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
                  else ...[
                    InkWell(
                      key: const Key('competition-award-event'),
                      onTap: _coreLocked ? null : _selectCompetitionEvent,
                      borderRadius: BorderRadius.circular(10),
                      child: InputDecorator(
                        decoration: const InputDecoration(
                          labelText: '选择目录赛事',
                          border: OutlineInputBorder(),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                _competitionEventId == null
                                    ? '搜索赛事名称 / 赛道'
                                    : _titleController.text,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: _competitionEventId == null
                                      ? CompetitionUiTokens.subColor(isDark)
                                      : CompetitionUiTokens.titleColor(isDark),
                                ),
                              ),
                            ),
                            Icon(
                              Icons.search_rounded,
                              color: CompetitionUiTokens.accent(isDark),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (_competitionEventId != null) ...[
                      const SizedBox(height: 12),
                      _textField(
                        _titleController,
                        '比赛名称（目录同步）',
                        enabled: false,
                      ),
                    ],
                  ],
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
                  _evidenceGrid(isDark),
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
              onPressed: _saving ||
                      _uploading ||
                      _evidenceItems.any((item) => item.failed)
                  ? null
                  : _save,
              icon: _saving
                  ? const SizedBox.square(
                      dimension: 17,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.save_outlined),
              label: Text(
                _saving
                    ? '保存中'
                    : _coreLocked
                        ? '保存可见范围'
                        : '保存',
              ),
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

  Widget _evidenceGrid(bool isDark) {
    final canAdd = !_coreLocked && _evidenceItems.length < 6;
    final itemCount = _evidenceItems.length + (canAdd ? 1 : 0);
    if (itemCount == 0) {
      return Text(
        '暂无证明材料',
        style: TextStyle(color: CompetitionUiTokens.subColor(isDark)),
      );
    }
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: itemCount,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 9,
        mainAxisSpacing: 9,
        childAspectRatio: .86,
      ),
      itemBuilder: (context, index) {
        if (canAdd && index == _evidenceItems.length) {
          return InkWell(
            key: const Key('competition-award-evidence'),
            onTap: _uploading ? null : _pickEvidence,
            borderRadius: BorderRadius.circular(10),
            child: Container(
              decoration: BoxDecoration(
                color: CompetitionUiTokens.accentSoft(isDark),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: CompetitionUiTokens.borderColor(isDark),
                ),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.add_photo_alternate_outlined,
                    color: CompetitionUiTokens.accent(isDark),
                  ),
                  const SizedBox(height: 5),
                  const Text('添加'),
                ],
              ),
            ),
          );
        }
        return _evidenceTile(_evidenceItems[index], isDark);
      },
    );
  }

  Widget _evidenceTile(_EvidencePreviewItem item, bool isDark) {
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: CompetitionUiTokens.accentSoft(isDark),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: CompetitionUiTokens.borderColor(isDark)),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (item.bytes != null)
            InkWell(
              onTap: () => _previewEvidence(item),
              child: Image.memory(item.bytes!, fit: BoxFit.cover),
            )
          else
            Icon(
              Icons.image_outlined,
              color: CompetitionUiTokens.subColor(isDark),
            ),
          if (item.uploading)
            ColoredBox(
              color: Colors.black.withValues(alpha: .42),
              child: const Center(
                child: CircularProgressIndicator(
                  color: Colors.white,
                  strokeWidth: 2,
                ),
              ),
            ),
          if (item.failed)
            ColoredBox(
              color: Colors.black.withValues(alpha: .58),
              child: Center(
                child: TextButton.icon(
                  onPressed: item.bytes == null
                      ? () => _loadEvidencePreview(item)
                      : () => _uploadEvidenceItem(item),
                  icon: const Icon(Icons.refresh_rounded, color: Colors.white),
                  label: const Text(
                    '重试',
                    style: TextStyle(color: Colors.white),
                  ),
                ),
              ),
            ),
          if (!_coreLocked && !item.uploading)
            Positioned(
              top: 3,
              right: 3,
              child: IconButton.filled(
                tooltip: '删除材料',
                visualDensity: VisualDensity.compact,
                style: IconButton.styleFrom(
                  backgroundColor: Colors.black.withValues(alpha: .55),
                  foregroundColor: Colors.white,
                ),
                onPressed: () => setState(() => _evidenceItems.remove(item)),
                icon: const Icon(Icons.close_rounded, size: 16),
              ),
            ),
        ],
      ),
    );
  }

  void _previewEvidence(_EvidencePreviewItem item) {
    final bytes = item.bytes;
    if (bytes == null) return;
    showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: .92),
      builder: (context) => Dialog.fullscreen(
        backgroundColor: Colors.black,
        child: Stack(
          children: [
            Center(
              child: InteractiveViewer(
                minScale: .8,
                maxScale: 5,
                child: Image.memory(bytes),
              ),
            ),
            SafeArea(
              child: Align(
                alignment: Alignment.topRight,
                child: IconButton(
                  tooltip: '关闭预览',
                  onPressed: () => Navigator.pop(context),
                  color: Colors.white,
                  icon: const Icon(Icons.close_rounded),
                ),
              ),
            ),
          ],
        ),
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

class _CompetitionEventPickerScreen extends StatefulWidget {
  final Dio dio;
  final int? initialEventId;
  final String initialTitle;

  const _CompetitionEventPickerScreen({
    required this.dio,
    required this.initialEventId,
    required this.initialTitle,
  });

  @override
  State<_CompetitionEventPickerScreen> createState() =>
      _CompetitionEventPickerScreenState();
}

class _CompetitionEventPickerScreenState
    extends State<_CompetitionEventPickerScreen> {
  static const _pageSize = 20;

  final _searchController = TextEditingController();
  final _scrollController = ScrollController();
  final List<CompetitionEvent> _events = [];
  Timer? _debounce;
  int _page = 0;
  int _requestSerial = 0;
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    _scrollController.addListener(_onScroll);
    _load(reset: true);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.removeListener(_onSearchChanged);
    _scrollController.removeListener(_onScroll);
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      _load(reset: true);
    });
  }

  void _onScroll() {
    if (_scrollController.position.extentAfter < 260 &&
        _hasMore &&
        !_loading &&
        !_loadingMore) {
      _load(reset: false);
    }
  }

  Future<void> _load({required bool reset}) async {
    final request = ++_requestSerial;
    final nextPage = reset ? 1 : _page + 1;
    setState(() {
      if (reset) {
        _loading = true;
        _error = null;
      } else {
        _loadingMore = true;
      }
    });
    try {
      final response = await widget.dio.get(
        '/competitions/events',
        queryParameters: {
          'keyword': _searchController.text.trim(),
          'page': nextPage,
          'page_size': _pageSize,
        },
      );
      final data = Map<String, dynamic>.from(response.data as Map);
      final items = ((data['items'] as List?) ?? const [])
          .map(
            (item) => CompetitionEvent.fromJson(
              Map<String, dynamic>.from(item as Map),
            ),
          )
          .toList();
      final total = (data['total'] as num?)?.toInt() ?? items.length;
      if (!mounted || request != _requestSerial) return;
      setState(() {
        if (reset) {
          _events
            ..clear()
            ..addAll(items);
        } else {
          final existingIds = _events.map((event) => event.id).toSet();
          _events.addAll(
            items.where((event) => existingIds.add(event.id)),
          );
        }
        _page = nextPage;
        _hasMore = items.length == _pageSize && _events.length < total;
        _loading = false;
        _loadingMore = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted || request != _requestSerial) return;
      setState(() {
        _loading = false;
        _loadingMore = false;
        _error = error is DioException
            ? AppFeedback.dioErrorMessage(error, fallback: '赛事目录加载失败')
            : '赛事目录数据解析失败';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return CompetitionPageScaffold(
      title: '选择目录赛事',
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
            child: TextField(
              key: const Key('competition-award-event-search'),
              controller: _searchController,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _load(reset: true),
              decoration: InputDecoration(
                hintText: '搜索赛事名称 / 赛道',
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: _searchController.text.isEmpty
                    ? null
                    : IconButton(
                        onPressed: _searchController.clear,
                        icon: const Icon(Icons.close_rounded),
                      ),
                border: const OutlineInputBorder(),
              ),
            ),
          ),
          Expanded(
            child: _buildResults(isDark),
          ),
        ],
      ),
    );
  }

  Widget _buildResults(bool isDark) {
    if (_loading && _events.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _events.isEmpty) {
      return Center(
        child: FilledButton.icon(
          onPressed: () => _load(reset: true),
          icon: const Icon(Icons.refresh_rounded),
          label: Text(_error!),
        ),
      );
    }
    if (_events.isEmpty) {
      return const Center(child: Text('没有找到匹配的目录赛事'));
    }
    return ListView(
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 24),
      children: [
        if (widget.initialEventId != null &&
            widget.initialTitle.trim().isNotEmpty) ...[
          Text(
            '最近选择',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: CompetitionUiTokens.subColor(isDark),
            ),
          ),
          const SizedBox(height: 6),
          _eventTile(
            CompetitionEvent(
              id: widget.initialEventId!,
              title: widget.initialTitle,
            ),
            isDark,
          ),
          const SizedBox(height: 12),
          Text(
            '赛事搜索结果',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: CompetitionUiTokens.subColor(isDark),
            ),
          ),
          const SizedBox(height: 6),
        ],
        for (final event in _events)
          if (event.id != widget.initialEventId) _eventTile(event, isDark),
        if (_loadingMore)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          ),
        if (_error != null && _events.isNotEmpty)
          TextButton.icon(
            onPressed: () => _load(reset: false),
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('下一页加载失败，点击重试'),
          ),
      ],
    );
  }

  Widget _eventTile(CompetitionEvent event, bool isDark) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: CompetitionUiTokens.cardBg(isDark),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: CompetitionUiTokens.borderColor(isDark)),
      ),
      child: ListTile(
        title: Text(
          event.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: () => Navigator.pop(context, event),
      ),
    );
  }
}
