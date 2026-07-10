import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/competition.dart';
import '../../providers/auth_provider.dart';
import '../../utils/app_feedback.dart';
import '../../widgets/competition/competition_ui_tokens.dart';

class CompetitionOfficialEventEditorScreen extends StatefulWidget {
  final Map<String, dynamic>? initialData;

  const CompetitionOfficialEventEditorScreen({super.key, this.initialData});

  @override
  State<CompetitionOfficialEventEditorScreen> createState() =>
      _CompetitionOfficialEventEditorScreenState();
}

class _CompetitionOfficialEventEditorScreenState
    extends State<CompetitionOfficialEventEditorScreen> {
  final _formKey = GlobalKey<FormState>();

  final _titleController = TextEditingController();
  final _summaryController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _tagsController = TextEditingController();
  final _importanceController = TextEditingController();
  final _competitionLevelController = TextEditingController();
  final _schoolGradeController = TextEditingController();
  final _targetAudienceController = TextEditingController();
  final _recommendationReasonController = TextEditingController();
  final _participationTypeController = TextEditingController();
  final _teamSizeMinController = TextEditingController();
  final _teamSizeMaxController = TextEditingController();
  final _organizerController = TextEditingController();
  final _hostUnitController = TextEditingController();
  final _registrationStartController = TextEditingController();
  final _registrationEndController = TextEditingController();
  final _eventStartController = TextEditingController();
  final _eventEndController = TextEditingController();
  final _registrationTextController = TextEditingController();
  final _eventTextController = TextEditingController();
  final _sortMonthController = TextEditingController();
  final _timeNoteController = TextEditingController();
  final _officialUrlController = TextEditingController();
  final _noticeUrlController = TextEditingController();
  final _sourceNoteController = TextEditingController();
  final _attachmentUrlsController = TextEditingController();

  List<CompetitionCategory> _categories = [];
  List<String> _eligibleEntryYears = [];
  List<String> _eligibleColleges = [];
  List<String> _eligibleMajors = [];
  List<String> _entryYearOptions = [];
  List<String> _collegeOptions = [];
  List<String> _majorOptions = [];
  String _categorySlug = '';
  String _recommendationLevel = 'B';
  String _schoolRecognitionStatus = 'pending';
  String _timeStatus = 'pending';
  String _timePrecision = 'unknown';
  String _sourceChannel = 'admin_manual';
  bool _isOnline = false;
  bool _loadingCategories = true;
  bool _categoryLoadFailed = false;
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    _fillInitialData();
    _loadCategories();
    _loadAudienceOptions();
  }

  @override
  void dispose() {
    for (final controller in [
      _titleController,
      _summaryController,
      _descriptionController,
      _tagsController,
      _importanceController,
      _competitionLevelController,
      _schoolGradeController,
      _targetAudienceController,
      _recommendationReasonController,
      _participationTypeController,
      _teamSizeMinController,
      _teamSizeMaxController,
      _organizerController,
      _hostUnitController,
      _registrationStartController,
      _registrationEndController,
      _eventStartController,
      _eventEndController,
      _registrationTextController,
      _eventTextController,
      _sortMonthController,
      _timeNoteController,
      _officialUrlController,
      _noticeUrlController,
      _sourceNoteController,
      _attachmentUrlsController,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _fillInitialData() {
    final d = widget.initialData ?? {};
    _titleController.text = '${d['title'] ?? ''}';
    _summaryController.text = '${d['summary'] ?? ''}';
    _descriptionController.text = '${d['description'] ?? ''}';
    _tagsController.text = _joinList(d['tags']);
    _categorySlug = _initialCategorySlug(d);
    _recommendationLevel = '${d['recommendation_level'] ?? 'B'}';
    _schoolRecognitionStatus = '${d['school_recognition_status'] ?? 'pending'}';
    _importanceController.text = '${d['importance_score'] ?? ''}';
    _competitionLevelController.text = '${d['competition_level'] ?? ''}';
    _schoolGradeController.text = '${d['school_recognition_grade'] ?? ''}';
    _targetAudienceController.text = '${d['target_audience'] ?? ''}';
    _eligibleEntryYears = _listValue(d['eligible_entry_years']);
    _eligibleColleges = _listValue(d['eligible_colleges']);
    _eligibleMajors = _listValue(d['eligible_majors']);
    _recommendationReasonController.text =
        '${d['recommendation_reason'] ?? ''}';
    _participationTypeController.text = '${d['participation_type'] ?? ''}';
    _teamSizeMinController.text = _blankZero(d['team_size_min']);
    _teamSizeMaxController.text = _blankZero(d['team_size_max']);
    _organizerController.text = '${d['organizer'] ?? ''}';
    _hostUnitController.text = '${d['host_unit'] ?? ''}';
    _timeStatus = '${d['time_status'] ?? 'pending'}';
    _timePrecision = '${d['time_precision'] ?? 'unknown'}';
    _registrationStartController.text = _dateOnly(d['registration_start']);
    _registrationEndController.text = _dateOnly(d['registration_end']);
    _eventStartController.text = _dateOnly(d['event_start']);
    _eventEndController.text = _dateOnly(d['event_end']);
    _registrationTextController.text = '${d['registration_time_text'] ?? ''}';
    _eventTextController.text = '${d['event_time_text'] ?? ''}';
    _sortMonthController.text = _blankZero(d['sort_month']);
    _timeNoteController.text = '${d['time_note'] ?? ''}';
    _officialUrlController.text = '${d['official_url'] ?? ''}';
    _noticeUrlController.text = '${d['notice_url'] ?? ''}';
    _sourceChannel = '${d['source_channel'] ?? 'admin_manual'}';
    _sourceNoteController.text = '${d['source_note'] ?? ''}';
    _attachmentUrlsController.text = _joinList(d['attachment_urls']);
    _isOnline = d['is_online'] == true;
  }

  Future<void> _loadCategories() async {
    setState(() {
      _loadingCategories = true;
      _categoryLoadFailed = false;
    });
    try {
      final resp = await context.read<AuthProvider>().dio.get(
            '/competitions/categories',
          );
      if (!mounted) return;
      final categories = ((resp.data as List?) ?? [])
          .map((item) => CompetitionCategory.fromJson(item))
          .toList();
      setState(() {
        _categories = categories;
        if (_categorySlug.isEmpty && categories.isNotEmpty) {
          _categorySlug = categories.first.slug;
        } else if (categories.isNotEmpty &&
            !categories.any((item) => item.slug == _categorySlug)) {
          _categorySlug = categories.first.slug;
        }
        _loadingCategories = false;
        _categoryLoadFailed = false;
      });
    } on DioException catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingCategories = false;
        _categoryLoadFailed = true;
      });
      AppFeedback.showSnackBar(
        context,
        AppFeedback.dioErrorMessage(e, fallback: '加载分类失败'),
        isError: true,
      );
    }
  }

  Future<void> _loadAudienceOptions() async {
    try {
      final response = await context
          .read<AuthProvider>()
          .dio
          .get('/admin/competitions/audience-options');
      final data = Map<String, dynamic>.from(response.data as Map);
      if (!mounted) return;
      setState(() {
        _entryYearOptions = _listValue(data['entry_years']);
        _collegeOptions = _listValue(data['colleges']);
        _majorOptions = _listValue(data['majors']);
      });
    } catch (_) {
      // 画像选项只是录入建议，加载失败时仍允许管理员手动输入。
    }
  }

  Future<void> _submit(String status) async {
    if (!_formKey.currentState!.validate()) return;
    if (_categorySlug.isEmpty) {
      AppFeedback.showSnackBar(context, '请选择分类', isError: true);
      return;
    }

    setState(() => _isSubmitting = true);
    try {
      final payload = {
        'title': _titleController.text.trim(),
        'summary': _summaryController.text.trim(),
        'description': _descriptionController.text.trim(),
        'primary_category_slug': _categorySlug,
        'tags': _splitList(_tagsController.text),
        'recommendation_level': _recommendationLevel,
        'importance_score':
            int.tryParse(_importanceController.text.trim()) ?? 0,
        'competition_level': _competitionLevelController.text.trim(),
        'school_recognition_status': _schoolRecognitionStatus,
        'school_recognition_grade': _schoolGradeController.text.trim(),
        'target_audience': _targetAudienceController.text.trim(),
        'eligible_entry_years': _eligibleEntryYears,
        'eligible_colleges': _eligibleColleges,
        'eligible_majors': _eligibleMajors,
        'recommendation_reason': _recommendationReasonController.text.trim(),
        'participation_type': _participationTypeController.text.trim(),
        'team_size_min': int.tryParse(_teamSizeMinController.text.trim()) ?? 0,
        'team_size_max': int.tryParse(_teamSizeMaxController.text.trim()) ?? 0,
        'organizer': _organizerController.text.trim(),
        'host_unit': _hostUnitController.text.trim(),
        'time_status': _timeStatus,
        'time_precision': _timePrecision,
        'registration_start': _registrationStartController.text.trim(),
        'registration_end': _registrationEndController.text.trim(),
        'event_start': _eventStartController.text.trim(),
        'event_end': _eventEndController.text.trim(),
        'registration_time_text': _registrationTextController.text.trim(),
        'event_time_text': _eventTextController.text.trim(),
        'sort_month': int.tryParse(_sortMonthController.text.trim()) ?? 0,
        'time_note': _timeNoteController.text.trim(),
        'official_url': _officialUrlController.text.trim(),
        'notice_url': _noticeUrlController.text.trim(),
        'attachment_urls': _splitList(_attachmentUrlsController.text),
        'source_channel': _sourceChannel,
        'source_note': _sourceNoteController.text.trim(),
        'is_online': _isOnline,
        'status': status,
      };

      final dio = context.read<AuthProvider>().dio;
      if (widget.initialData != null && widget.initialData!['id'] != null) {
        await dio.put(
          '/admin/competitions/events/${widget.initialData!['id']}',
          data: payload,
        );
        if (!mounted) return;
        AppFeedback.showSnackBar(context, '更新成功');
      } else {
        await dio.post('/admin/competitions/events', data: payload);
        if (!mounted) return;
        AppFeedback.showSnackBar(
          context,
          status == 'draft' ? '已保存为草稿' : '发布成功',
        );
      }
      Navigator.pop(context, true);
    } on DioException catch (e) {
      if (!mounted) return;
      AppFeedback.showSnackBar(
        context,
        AppFeedback.dioErrorMessage(e, fallback: '操作失败'),
        isError: true,
      );
    } catch (e) {
      if (!mounted) return;
      AppFeedback.showSnackBar(context, '发生错误：$e', isError: true);
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = CompetitionUiTokens.pageBg(isDark);

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        surfaceTintColor: Colors.transparent,
        title: Text(widget.initialData == null ? '手动新建公开比赛' : '编辑公开比赛'),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 108),
          children: [
            _section(
              '基础信息',
              Icons.article_outlined,
              isDark,
              [
                _input(_titleController, '比赛名称', isDark, required: true),
                _input(_summaryController, '一句话简介', isDark),
                _input(
                  _descriptionController,
                  '比赛说明',
                  isDark,
                  minLines: 3,
                  maxLines: 5,
                ),
                _categoryDropdown(isDark),
                _input(_tagsController, '标签，逗号分隔', isDark),
              ],
            ),
            _section(
              '推荐与认定',
              Icons.workspace_premium_outlined,
              isDark,
              [
                Row(
                  children: [
                    Expanded(
                      child: _dropdown(
                        label: '推荐等级',
                        value: _recommendationLevel,
                        items: const ['S', 'A', 'B+', 'B', 'B-', 'C', 'D', 'E'],
                        isDark: isDark,
                        onChanged: (value) =>
                            setState(() => _recommendationLevel = value),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _input(
                        _importanceController,
                        '重要分',
                        isDark,
                        keyboardType: TextInputType.number,
                      ),
                    ),
                  ],
                ),
                _input(_competitionLevelController, '比赛级别', isDark),
                Row(
                  children: [
                    Expanded(
                      child: _dropdown(
                        label: '学校认定状态',
                        value: _schoolRecognitionStatus,
                        items: const [
                          'recognized',
                          'not_recognized',
                          'pending',
                          'unknown',
                        ],
                        labelBuilder: _recognitionLabel,
                        isDark: isDark,
                        onChanged: (value) =>
                            setState(() => _schoolRecognitionStatus = value),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _input(_schoolGradeController, '学校目录类别', isDark),
                    ),
                  ],
                ),
                _input(_targetAudienceController, '适合人群', isDark),
                _multiValueEditor(
                  label: '适用入学年份',
                  hint: '例如 2023；留空表示不限',
                  values: _eligibleEntryYears,
                  options: _entryYearOptions,
                  isDark: isDark,
                  onChanged: (values) =>
                      setState(() => _eligibleEntryYears = values),
                ),
                _multiValueEditor(
                  label: '适用学院',
                  hint: '选择或输入学院；留空表示不限',
                  values: _eligibleColleges,
                  options: _collegeOptions,
                  isDark: isDark,
                  onChanged: (values) =>
                      setState(() => _eligibleColleges = values),
                ),
                _multiValueEditor(
                  label: '适用专业',
                  hint: '选择或输入专业；留空表示不限',
                  values: _eligibleMajors,
                  options: _majorOptions,
                  isDark: isDark,
                  onChanged: (values) =>
                      setState(() => _eligibleMajors = values),
                ),
                _input(_participationTypeController, '参赛形式', isDark),
                Row(
                  children: [
                    Expanded(
                      child: _input(
                        _teamSizeMinController,
                        '最少人数',
                        isDark,
                        keyboardType: TextInputType.number,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _input(
                        _teamSizeMaxController,
                        '最多人数',
                        isDark,
                        keyboardType: TextInputType.number,
                      ),
                    ),
                  ],
                ),
                _input(
                  _recommendationReasonController,
                  '推荐理由',
                  isDark,
                  minLines: 2,
                  maxLines: 4,
                ),
              ],
            ),
            _section(
              '时间安排',
              Icons.event_note_outlined,
              isDark,
              [
                Row(
                  children: [
                    Expanded(
                      child: _dropdown(
                        label: '时间状态',
                        value: _timeStatus,
                        items: const [
                          'confirmed',
                          'estimated',
                          'historical',
                          'pending',
                        ],
                        labelBuilder: _timeStatusLabel,
                        isDark: isDark,
                        onChanged: (value) =>
                            setState(() => _timeStatus = value),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _dropdown(
                        label: '时间精度',
                        value: _timePrecision,
                        items: const [
                          'exact',
                          'month',
                          'month_range',
                          'quarter',
                          'half_year',
                          'season',
                          'unknown',
                        ],
                        labelBuilder: _timePrecisionLabel,
                        isDark: isDark,
                        onChanged: (value) =>
                            setState(() => _timePrecision = value),
                      ),
                    ),
                  ],
                ),
                Row(
                  children: [
                    Expanded(
                      child: _input(
                        _registrationStartController,
                        '报名开始',
                        isDark,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _input(_registrationEndController, '报名结束', isDark),
                    ),
                  ],
                ),
                Row(
                  children: [
                    Expanded(
                      child: _input(_eventStartController, '比赛开始', isDark),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _input(_eventEndController, '比赛结束', isDark),
                    ),
                  ],
                ),
                _input(_registrationTextController, '原文报名时间', isDark),
                _input(_eventTextController, '原文比赛时间', isDark),
                Row(
                  children: [
                    Expanded(
                      child: _input(
                        _sortMonthController,
                        '排序月份',
                        isDark,
                        keyboardType: TextInputType.number,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: SwitchListTile(
                        value: _isOnline,
                        onChanged: (value) => setState(() => _isOnline = value),
                        contentPadding: EdgeInsets.zero,
                        title: const Text('线上比赛'),
                        activeThumbColor: Colors.white,
                        activeTrackColor: CompetitionUiTokens.accent(isDark),
                      ),
                    ),
                  ],
                ),
                _input(_timeNoteController, '时间说明', isDark),
              ],
            ),
            _section(
              '来源与发布',
              Icons.source_outlined,
              isDark,
              [
                _input(_organizerController, '主办方', isDark),
                _input(_hostUnitController, '承办/指导单位', isDark),
                _input(_officialUrlController, '官网链接', isDark),
                _input(_noticeUrlController, '通知链接', isDark),
                _input(_attachmentUrlsController, '附件链接，逗号分隔', isDark),
                _dropdown(
                  label: '来源渠道',
                  value: _sourceChannel,
                  items: const [
                    'school_catalog',
                    'college_notice',
                    'enterprise',
                    'industry_association',
                    'platform',
                    'admin_manual',
                    'ai_import',
                  ],
                  labelBuilder: _sourceLabel,
                  isDark: isDark,
                  onChanged: (value) => setState(() => _sourceChannel = value),
                ),
                _input(
                  _sourceNoteController,
                  '来源说明',
                  isDark,
                  minLines: 2,
                  maxLines: 4,
                ),
              ],
            ),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          decoration: BoxDecoration(
            color: bg,
            border: Border(
              top: BorderSide(color: CompetitionUiTokens.borderColor(isDark)),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _isSubmitting ? null : () => _submit('draft'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(44),
                    foregroundColor: CompetitionUiTokens.titleColor(isDark),
                    side: BorderSide(
                      color: CompetitionUiTokens.borderColor(isDark),
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: const Text('保存草稿'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: _isSubmitting ? null : () => _submit('published'),
                  style: FilledButton.styleFrom(
                    backgroundColor: CompetitionUiTokens.accent(isDark),
                    foregroundColor: Colors.white,
                    minimumSize: const Size.fromHeight(44),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: Text(_isSubmitting ? '提交中...' : '发布'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _section(
    String title,
    IconData icon,
    bool isDark,
    List<Widget> children,
  ) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(16),
      decoration: CompetitionUiTokens.cardDecoration(isDark),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                icon,
                size: 18,
                color: CompetitionUiTokens.accent(isDark),
              ),
              const SizedBox(width: 8),
              Text(
                title,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w900,
                  color: CompetitionUiTokens.titleColor(isDark),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          for (final child in children) ...[
            child,
            if (child != children.last) const SizedBox(height: 12),
          ],
        ],
      ),
    );
  }

  Widget _input(
    TextEditingController controller,
    String label,
    bool isDark, {
    bool required = false,
    int minLines = 1,
    int maxLines = 1,
    TextInputType? keyboardType,
  }) {
    return TextFormField(
      controller: controller,
      minLines: minLines,
      maxLines: maxLines,
      keyboardType: keyboardType,
      decoration: _inputDecoration(required ? '$label *' : label, isDark),
      validator: required
          ? (value) => (value ?? '').trim().isEmpty ? '必填' : null
          : null,
    );
  }

  Widget _categoryDropdown(bool isDark) {
    if (_categoryLoadFailed && _categories.isEmpty) {
      return OutlinedButton.icon(
        onPressed: _loadingCategories ? null : _loadCategories,
        icon: const Icon(Icons.refresh_rounded, size: 18),
        label: const Text('重新加载分类'),
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(44),
          foregroundColor: CompetitionUiTokens.accent(isDark),
          side: BorderSide(color: CompetitionUiTokens.borderColor(isDark)),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      );
    }
    final value = _categories.any((item) => item.slug == _categorySlug)
        ? _categorySlug
        : null;
    return DropdownButtonFormField<String>(
      initialValue: value,
      decoration: _inputDecoration(
        _loadingCategories ? '正在加载分类' : '分类 *',
        isDark,
      ),
      items: _categories
          .map(
            (category) => DropdownMenuItem(
              value: category.slug,
              child: Text(category.name),
            ),
          )
          .toList(),
      validator: (value) => value == null || value.isEmpty ? '请选择分类' : null,
      onChanged: _loadingCategories
          ? null
          : (value) => setState(() => _categorySlug = value ?? ''),
    );
  }

  Widget _dropdown({
    required String label,
    required String value,
    required List<String> items,
    required bool isDark,
    required ValueChanged<String> onChanged,
    String Function(String value)? labelBuilder,
  }) {
    final selected = items.contains(value) ? value : items.first;
    return DropdownButtonFormField<String>(
      initialValue: selected,
      decoration: _inputDecoration(label, isDark),
      items: items
          .map(
            (item) => DropdownMenuItem(
              value: item,
              child: Text(labelBuilder?.call(item) ?? item),
            ),
          )
          .toList(),
      onChanged: (value) {
        if (value != null) onChanged(value);
      },
    );
  }

  Widget _multiValueEditor({
    required String label,
    required String hint,
    required List<String> values,
    required List<String> options,
    required bool isDark,
    required ValueChanged<List<String>> onChanged,
  }) {
    void addValue(String raw) {
      final value = raw.trim();
      if (value.isEmpty || values.contains(value)) return;
      onChanged([...values, value]);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Autocomplete<String>(
          optionsBuilder: (text) {
            final query = text.text.trim().toLowerCase();
            if (query.isEmpty) return options.take(12);
            return options
                .where((item) => item.toLowerCase().contains(query))
                .take(12);
          },
          onSelected: addValue,
          fieldViewBuilder: (context, controller, focusNode, onSubmitted) {
            return TextFormField(
              controller: controller,
              focusNode: focusNode,
              decoration: _inputDecoration(label, isDark).copyWith(
                hintText: hint,
                helperText: '输入后回车添加；留空表示不限',
              ),
              onFieldSubmitted: (value) {
                addValue(value);
                controller.clear();
              },
            );
          },
        ),
        if (values.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: values
                .map(
                  (value) => InputChip(
                    label: Text(value),
                    onDeleted: () => onChanged(
                      values.where((item) => item != value).toList(),
                    ),
                  ),
                )
                .toList(),
          ),
        ],
      ],
    );
  }

  InputDecoration _inputDecoration(String label, bool isDark) {
    return InputDecoration(
      labelText: label,
      filled: true,
      fillColor: CompetitionUiTokens.cardBg(isDark),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: CompetitionUiTokens.borderColor(isDark)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: CompetitionUiTokens.borderColor(isDark)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(
          color: CompetitionUiTokens.accent(isDark),
          width: 1.3,
        ),
      ),
    );
  }

  String _initialCategorySlug(Map<String, dynamic> data) {
    final direct = '${data['primary_category_slug'] ?? ''}'.trim();
    if (direct.isNotEmpty) return direct;
    final category = data['primary_category'];
    if (category is Map) return '${category['slug'] ?? ''}'.trim();
    return '';
  }

  String _dateOnly(dynamic value) {
    final raw = '${value ?? ''}'.trim();
    if (raw.isEmpty || raw == 'null') return '';
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return raw;
    return '${parsed.year}-${parsed.month.toString().padLeft(2, '0')}-${parsed.day.toString().padLeft(2, '0')}';
  }

  String _blankZero(dynamic value) {
    final text = '${value ?? ''}'.trim();
    if (text == '0' || text == 'null') return '';
    return text;
  }

  String _joinList(dynamic value) {
    if (value is List) {
      return value
          .map((item) => '$item'.trim())
          .where((item) => item.isNotEmpty)
          .join('，');
    }
    return '${value ?? ''}'.trim();
  }

  List<String> _listValue(dynamic value) {
    if (value is! List) return [];
    return value
        .map((item) => '$item'.trim())
        .where((item) => item.isNotEmpty)
        .toList();
  }

  List<String> _splitList(String value) {
    return value
        .split(RegExp(r'[,，\n]'))
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList();
  }
}

String _recognitionLabel(String value) {
  switch (value) {
    case 'recognized':
      return '已认定';
    case 'not_recognized':
      return '未认定';
    case 'pending':
      return '待确认';
    case 'unknown':
      return '未知';
    default:
      return value;
  }
}

String _timeStatusLabel(String value) {
  switch (value) {
    case 'confirmed':
      return '已确认';
    case 'estimated':
      return '预计时间';
    case 'historical':
      return '往年参考';
    case 'pending':
      return '时间待公布';
    default:
      return value;
  }
}

String _timePrecisionLabel(String value) {
  switch (value) {
    case 'exact':
      return '精确到日';
    case 'month':
      return '按月份';
    case 'month_range':
      return '月份范围';
    case 'quarter':
      return '季度';
    case 'half_year':
      return '半年';
    case 'season':
      return '季节';
    case 'unknown':
      return '未知';
    default:
      return value;
  }
}

String _sourceLabel(String value) {
  switch (value) {
    case 'school_catalog':
      return '学校目录';
    case 'college_notice':
      return '学院通知';
    case 'enterprise':
      return '企业赛事';
    case 'industry_association':
      return '行业协会';
    case 'platform':
      return '平台赛事';
    case 'admin_manual':
      return '管理员录入';
    case 'ai_import':
      return 'AI导入';
    default:
      return value;
  }
}
