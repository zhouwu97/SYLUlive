import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../config/api_constants.dart';
import '../../models/poll_visibility.dart';
import '../../models/post.dart';
import '../../providers/poll_provider.dart';
import '../../services/poll_service.dart';
import '../../utils/app_feedback.dart';
import '../../widgets/campus/campus_theme.dart';
import 'widgets/poll_option_editor.dart';
import 'widgets/poll_setting_row.dart';

class PollComposerScreen extends StatefulWidget {
  final Post? editingPost;

  const PollComposerScreen({super.key, this.editingPost});

  @override
  State<PollComposerScreen> createState() => _PollComposerScreenState();
}

class _PollComposerScreenState extends State<PollComposerScreen> {
  static const _accent = CampusTheme.primary;
  static const _categoryNames = {
    'campus_life': '校园生活',
    'study': '学习',
    'activity': '活动',
    'other': '其他'
  };
  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _titleFocus = FocusNode();
  final List<TextEditingController> _optionControllers = [];
  final List<XFile> _newImages = [];
  final List<PostImage> _existingImages = [];
  bool _submitting = false;
  String _category = 'campus_life';
  String _selectionMode = 'single';
  int _maxChoices = 1;
  String _resultsVisibility = PollVisibility.always;
  bool _allowChange = true;
  int? _durationHours = 72;
  DateTime? _customEndsAt;
  String? _titleError;

  bool get _isEditing => widget.editingPost != null;
  bool get _rulesLocked =>
      (widget.editingPost?.pollMeta?.participantCount ?? 0) > 0;

  @override
  void initState() {
    super.initState();
    final post = widget.editingPost;
    if (post != null && post.pollMeta != null) {
      final poll = post.pollMeta!;
      _titleController.text = post.title;
      _descriptionController.text = post.content;
      _category = poll.category;
      _selectionMode = poll.selectionMode;
      _maxChoices = poll.maxChoices;
      _resultsVisibility =
          poll.resultsVisibility == 'after_vote' && !_rulesLocked
              ? PollVisibility.afterEnd
              : poll.resultsVisibility;
      _allowChange = poll.allowChange;
      _durationHours = null;
      _customEndsAt = poll.endsAt;
      _existingImages.addAll(post.images);
      for (final option in poll.options) {
        _optionControllers.add(TextEditingController(text: option.text));
      }
    }
    while (_optionControllers.length < 2) {
      _optionControllers.add(TextEditingController());
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    _titleFocus.dispose();
    for (final controller in _optionControllers) {
      controller.dispose();
    }
    super.dispose();
  }

  DateTime get _endsAt => _durationHours != null
      ? DateTime.now().add(Duration(hours: _durationHours!))
      : _customEndsAt!;

  Future<void> _pickImages() async {
    final remaining = 3 - _existingImages.length - _newImages.length;
    if (remaining <= 0) return;
    final picked = await ImagePicker().pickMultiImage(imageQuality: 88);
    if (!mounted) return;
    setState(() => _newImages.addAll(picked.take(remaining)));
  }

  Future<void> _pickCustomEnd() async {
    final now = DateTime.now();
    final initial = _customEndsAt ?? now.add(const Duration(days: 3));
    final date = await showDatePicker(
      context: context,
      firstDate: now,
      lastDate: now.add(const Duration(days: 30)),
      initialDate: initial,
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
        context: context, initialTime: TimeOfDay.fromDateTime(initial));
    if (time == null || !mounted) return;
    final value =
        DateTime(date.year, date.month, date.day, time.hour, time.minute);
    if (value.isBefore(now.add(const Duration(minutes: 30)))) {
      AppFeedback.info('截止时间至少晚于当前时间 30 分钟', context: context);
      return;
    }
    setState(() {
      _durationHours = null;
      _customEndsAt = value;
    });
  }

  String? _validate() {
    final title = _titleController.text.trim();
    if (title.isEmpty) {
      setState(() => _titleError = '请输入投票标题');
      _titleFocus.requestFocus();
      return _titleError;
    }
    final options =
        _optionControllers.map((controller) => controller.text.trim()).toList();
    if (options.any((option) => option.isEmpty)) return '请填写全部投票选项';
    if (options.map((option) => option.toLowerCase()).toSet().length !=
        options.length) {
      return '投票选项不能重复';
    }
    if (_selectionMode == 'multiple' &&
        (_maxChoices < 2 || _maxChoices > options.length)) {
      return '最大可选数量超出选项范围';
    }
    return null;
  }

  Future<void> _submit() async {
    final error = _validate();
    if (error != null) {
      AppFeedback.error(error, context: context);
      return;
    }
    setState(() => _submitting = true);
    final provider = context.read<PollProvider>();
    try {
      final uploaded = _newImages.isEmpty
          ? <int>[]
          : await provider.service.uploadImages(_newImages);
      final draft = PollDraft(
        title: _titleController.text.trim(),
        description: _descriptionController.text.trim(),
        category: _category,
        selectionMode: _selectionMode,
        maxChoices: _selectionMode == 'single' ? 1 : _maxChoices,
        resultsVisibility: _resultsVisibility,
        allowChange: _allowChange,
        endsAt: _endsAt,
        options: _optionControllers
            .map((controller) => controller.text.trim())
            .toList(),
        fileIds: [..._existingImages.map((image) => image.fileId), ...uploaded],
      );
      final pollId = widget.editingPost?.pollMeta?.id;
      final result = pollId == null
          ? await provider.createPoll(draft)
          : await provider.updatePoll(pollId, draft);
      if (!mounted) return;
      if (result == null) {
        final message = pollId == null
            ? provider.lastActionError
            : provider.mutationError(pollId);
        AppFeedback.error(
          message ?? (_isEditing ? '更新失败' : '发布失败'),
          context: context,
        );
        return;
      }
      Navigator.pop(context, result);
    } on PollApiException catch (error) {
      if (mounted) {
        AppFeedback.error(error.message, context: context);
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _preview() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_titleController.text.trim().isEmpty
            ? '投票预览'
            : _titleController.text.trim()),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: _optionControllers
              .map((controller) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Row(children: [
                      const Icon(Icons.radio_button_off,
                          size: 19, color: _accent),
                      const SizedBox(width: 8),
                      Expanded(
                          child: Text(controller.text.trim().isEmpty
                              ? '未填写选项'
                              : controller.text.trim())),
                    ]),
                  ))
              .toList(),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('关闭'))
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: CampusTheme.pageBackground(context),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        title: Text(
          _isEditing ? '编辑投票' : '发起投票',
          style: const TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: CampusTheme.text,
          ),
        ),
        iconTheme: const IconThemeData(color: CampusTheme.text),
        actions: [
          TextButton.icon(
            onPressed: _preview,
            icon: const Icon(Icons.visibility_outlined, size: 20),
            label: const Text('预览', style: TextStyle(fontSize: 14)),
            style: TextButton.styleFrom(foregroundColor: CampusTheme.subText),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 110),
          children: [
            if (_rulesLocked) const _Notice(text: '已有用户参与，为保证公平，只能修改补充说明和图片。'),
            Stack(
              alignment: Alignment.bottomRight,
              children: [
                TextField(
                  controller: _titleController,
                  focusNode: _titleFocus,
                  enabled: !_rulesLocked,
                  maxLength: 80,
                  onChanged: (_) {
                    if (_titleError != null) setState(() => _titleError = null);
                    setState(() {});
                  },
                  decoration: InputDecoration(
                    hintText: '投票标题',
                    errorText: _titleError,
                    counterText: '',
                    filled: true,
                    fillColor: Colors.white,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 14),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide:
                          const BorderSide(color: CampusTheme.border, width: 1),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(
                          color: CampusTheme.primary, width: 1),
                    ),
                  ),
                ),
                Padding(
                  padding: EdgeInsets.only(
                      right: 12, bottom: _titleError != null ? 30 : 12),
                  child: Text('${_titleController.text.length}/80',
                      style: const TextStyle(
                          fontSize: 11, color: CampusTheme.subText)),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Stack(
              alignment: Alignment.bottomRight,
              children: [
                TextField(
                  controller: _descriptionController,
                  maxLength: 1000,
                  minLines: 4,
                  maxLines: 6,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: '补充说明（可选）',
                    alignLabelWithHint: true,
                    counterText: '',
                    filled: true,
                    fillColor: Colors.white,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 14),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide:
                          const BorderSide(color: CampusTheme.border, width: 1),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(
                          color: CampusTheme.primary, width: 1),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(right: 12, bottom: 12),
                  child: Text('${_descriptionController.text.length}/1000',
                      style: const TextStyle(
                          fontSize: 11, color: CampusTheme.subText)),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Row(children: [
              Expanded(child: _sectionTitle('图片（最多 3 张）')),
              Text('${_existingImages.length + _newImages.length}/3',
                  style: const TextStyle(
                      fontSize: 13, color: CampusTheme.subText)),
            ]),
            const SizedBox(height: 10),
            SizedBox(
              height: 108,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  ..._existingImages.asMap().entries.map((entry) =>
                      _ExistingImage(
                        image: entry.value,
                        onRemove: () =>
                            setState(() => _existingImages.removeAt(entry.key)),
                      )),
                  ..._newImages.asMap().entries.map((entry) => _NewImage(
                        image: entry.value,
                        onRemove: () =>
                            setState(() => _newImages.removeAt(entry.key)),
                      )),
                  if (_existingImages.length + _newImages.length < 3)
                    InkWell(
                      onTap: _pickImages,
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        width: 108,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          border: Border.all(
                              color:
                                  CampusTheme.primary.withValues(alpha: 0.3)),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.add, size: 34, color: _accent),
                            SizedBox(height: 6),
                            Text('添加图片',
                                style: TextStyle(fontSize: 13, color: _accent)),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Row(children: [
              Expanded(child: _sectionTitle('投票选项')),
              Text('${_optionControllers.length}/10',
                  style: TextStyle(color: Theme.of(context).hintColor)),
            ]),
            const SizedBox(height: 8),
            ReorderableListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _optionControllers.length,
              onReorder: _rulesLocked
                  ? (_, __) {}
                  : (oldIndex, newIndex) {
                      if (newIndex > oldIndex) newIndex--;
                      setState(() {
                        final item = _optionControllers.removeAt(oldIndex);
                        _optionControllers.insert(newIndex, item);
                      });
                    },
              itemBuilder: (context, index) => Padding(
                key: ValueKey(_optionControllers[index]),
                padding: const EdgeInsets.only(bottom: 6),
                child: PollOptionEditor(
                  index: index,
                  controller: _optionControllers[index],
                  enabled: !_rulesLocked,
                  canDelete: _optionControllers.length > 2,
                  onDelete: () => setState(() {
                    final controller = _optionControllers.removeAt(index);
                    controller.dispose();
                    if (_maxChoices > _optionControllers.length) {
                      _maxChoices = _optionControllers.length;
                    }
                  }),
                ),
              ),
            ),
            if (!_rulesLocked && _optionControllers.length < 10)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => setState(
                      () => _optionControllers.add(TextEditingController())),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('添加选项'),
                  style: TextButton.styleFrom(
                    foregroundColor: CampusTheme.primary,
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    minimumSize: const Size(0, 36),
                  ),
                ),
              ),
            const SizedBox(height: 14),
            _sectionTitle('投票设置'),
            const SizedBox(height: 7),
            Container(
              decoration: BoxDecoration(
                color: isDark ? CampusTheme.darkCard : CampusTheme.card,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.08)
                      : CampusTheme.softBorder,
                ),
              ),
              child: Column(
                children: [
                  PollSettingRow(
                    icon: Icons.grid_view_rounded,
                    title: '分类',
                    trailing: PopupMenuButton<String>(
                      initialValue: _category,
                      enabled: !_rulesLocked,
                      color: Colors.white,
                      elevation: 3,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                      position: PopupMenuPosition.under,
                      onSelected: (value) => setState(() => _category = value),
                      itemBuilder: (_) => _categoryNames.entries
                          .map((entry) => PopupMenuItem(
                              value: entry.key,
                              child: Text(entry.value,
                                  style: const TextStyle(fontSize: 14))))
                          .toList(),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Text(_categoryNames[_category]!,
                            style: const TextStyle(fontSize: 14)),
                        const SizedBox(width: 4),
                        const Icon(Icons.chevron_right,
                            size: 20, color: CampusTheme.subText),
                      ]),
                    ),
                  ),
                  PollSettingRow(
                    icon: Icons.check_circle,
                    title: '选择方式',
                    trailing: _buildSelectionControl(),
                  ),
                  if (_selectionMode == 'multiple')
                    PollSettingRow(
                      icon: Icons.format_list_numbered,
                      title: '每人最多选择',
                      trailing: PopupMenuButton<int>(
                        initialValue:
                            _maxChoices.clamp(2, _optionControllers.length),
                        enabled: !_rulesLocked,
                        color: Colors.white,
                        elevation: 3,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                        position: PopupMenuPosition.under,
                        onSelected: (value) =>
                            setState(() => _maxChoices = value),
                        itemBuilder: (_) => List.generate(
                                (_optionControllers.length - 1).clamp(1, 9),
                                (index) => index + 2)
                            .map((value) => PopupMenuItem(
                                value: value,
                                child: Text('$value 项',
                                    style: const TextStyle(fontSize: 14))))
                            .toList(),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Text(
                              '${_maxChoices.clamp(2, _optionControllers.length)} 项',
                              style: const TextStyle(fontSize: 14)),
                          const SizedBox(width: 4),
                          const Icon(Icons.chevron_right,
                              size: 20, color: CampusTheme.subText),
                        ]),
                      ),
                    ),
                  PollSettingRow(
                    icon: Icons.schedule,
                    title: '截止时间',
                    subtitle: _durationHours == null
                        ? _formatDate(_customEndsAt!)
                        : null,
                    trailing: PopupMenuButton<int>(
                      enabled: !_rulesLocked,
                      color: Colors.white,
                      elevation: 3,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                      position: PopupMenuPosition.under,
                      onSelected: (value) {
                        if (value == -1) {
                          _pickCustomEnd();
                        } else {
                          setState(() => _durationHours = value);
                        }
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 1, child: Text('1 小时')),
                        PopupMenuItem(value: 24, child: Text('1 天')),
                        PopupMenuItem(value: 72, child: Text('3 天')),
                        PopupMenuItem(value: 168, child: Text('7 天')),
                        PopupMenuItem(value: -1, child: Text('自定义')),
                      ],
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Text(_durationLabel(),
                            style: const TextStyle(fontSize: 14)),
                        const SizedBox(width: 4),
                        const Icon(Icons.chevron_right,
                            size: 20, color: CampusTheme.subText),
                      ]),
                    ),
                  ),
                  _buildVisibilitySelector(isDark),
                  PollSettingRow(
                    icon: Icons.lock_outline,
                    title: '允许修改选择',
                    showDivider: false,
                    trailing: Switch(
                      value: _allowChange,
                      activeThumbColor: Colors.white,
                      activeTrackColor: CampusTheme.primary,
                      onChanged: _rulesLocked
                          ? null
                          : (value) => setState(() => _allowChange = value),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.security, size: 14, color: CampusTheme.primary),
                SizedBox(width: 4),
                Text('投票默认匿名，仅展示汇总结果',
                    style: TextStyle(fontSize: 12, color: CampusTheme.subText)),
              ],
            ),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: SizedBox(
          height: 48,
          child: FilledButton.icon(
            onPressed: _submitting ? null : _submit,
            style: FilledButton.styleFrom(
                backgroundColor: _accent,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8))),
            icon: _submitting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.near_me_outlined, size: 18),
            label: Text(_isEditing ? '保存修改' : '发布投票',
                style: const TextStyle(fontSize: 15)),
          ),
        ),
      ),
    );
  }

  Widget _sectionTitle(String title) => Text(title,
      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700));

  String _durationLabel() {
    switch (_durationHours) {
      case 1:
        return '1 小时';
      case 24:
        return '1 天';
      case 72:
        return '3 天';
      case 168:
        return '7 天';
      default:
        return '自定义';
    }
  }

  String _formatDate(DateTime value) =>
      '${value.month}月${value.day}日 ${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';

  Widget _buildSelectionControl() {
    return Container(
      height: 32,
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: CampusTheme.border),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildSegment('single', '单选', true),
          _buildSegment('multiple', '多选', false),
        ],
      ),
    );
  }

  Widget _buildVisibilitySelector(bool isDark) {
    final legacyLocked = _rulesLocked && _resultsVisibility == 'after_vote';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 6),
          child: Row(
            children: [
              const Icon(
                Icons.visibility_outlined,
                size: 19,
                color: CampusTheme.primary,
              ),
              const SizedBox(width: 12),
              Text(
                '结果展示',
                style: TextStyle(
                  fontSize: 14,
                  color: isDark ? Colors.white : const Color(0xFF1F2328),
                ),
              ),
            ],
          ),
        ),
        if (legacyLocked)
          const Padding(
            padding: EdgeInsets.fromLTRB(46, 4, 14, 12),
            child: Text(
              '该历史投票为“投票后可见”，已有参与记录，规则不可修改。',
              style: TextStyle(fontSize: 12, color: CampusTheme.subText),
            ),
          )
        else
          RadioGroup<String>(
            groupValue: _resultsVisibility,
            onChanged: _rulesLocked
                ? (_) {}
                : (value) {
                    if (value == null) return;
                    setState(() => _resultsVisibility = value);
                  },
            child: Column(
              children: [
                for (final option in PollVisibility.createOptions)
                  RadioListTile<String>(
                    value: option.value,
                    enabled: !_rulesLocked,
                    activeColor: CampusTheme.primary,
                    dense: true,
                    visualDensity: VisualDensity.compact,
                    contentPadding: const EdgeInsets.only(left: 34, right: 12),
                    title: Text(
                      option.title,
                      style: TextStyle(
                        fontSize: 13.5,
                        color: isDark ? Colors.white : const Color(0xFF1F2328),
                      ),
                    ),
                    subtitle: Text(
                      option.description,
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: CampusTheme.subText,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        const Padding(
          padding: EdgeInsets.only(left: 47),
          child: Divider(
            height: 1,
            thickness: 0.5,
            color: Color(0xFFE2EFEA),
          ),
        ),
      ],
    );
  }

  Widget _buildSegment(String value, String label, bool isLeft) {
    final isSelected = _selectionMode == value;
    return GestureDetector(
      onTap: _rulesLocked
          ? null
          : () => setState(() {
                _selectionMode = value;
                _maxChoices = _selectionMode == 'single' ? 1 : 2;
              }),
      child: Container(
        width: 60,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: isSelected ? CampusTheme.primaryLight : Colors.transparent,
          borderRadius: isLeft
              ? const BorderRadius.horizontal(left: Radius.circular(5))
              : const BorderRadius.horizontal(right: Radius.circular(5)),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            color: isSelected ? CampusTheme.primary : CampusTheme.subText,
          ),
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  static const _noticeAccent = CampusTheme.primary;
  final String text;
  const _Notice({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: CampusTheme.primaryLight,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Icon(Icons.info_outline, size: 19, color: _noticeAccent),
        const SizedBox(width: 8),
        Expanded(
            child: Text(text,
                style: const TextStyle(fontSize: 12.5, height: 1.4))),
      ]),
    );
  }
}

class _ExistingImage extends StatelessWidget {
  final PostImage image;
  final VoidCallback onRemove;
  const _ExistingImage({required this.image, required this.onRemove});

  @override
  Widget build(BuildContext context) => _ImageFrame(
        onRemove: onRemove,
        child: CachedNetworkImage(
            imageUrl: ApiConstants.fullUrl(image.url), fit: BoxFit.cover),
      );
}

class _NewImage extends StatelessWidget {
  final XFile image;
  final VoidCallback onRemove;
  const _NewImage({required this.image, required this.onRemove});

  @override
  Widget build(BuildContext context) => _ImageFrame(
        onRemove: onRemove,
        child: kIsWeb
            ? Image.network(image.path, fit: BoxFit.cover)
            : FutureBuilder<Uint8List>(
                future: image.readAsBytes(),
                builder: (_, snapshot) => snapshot.hasData
                    ? Image.memory(snapshot.data!, fit: BoxFit.cover)
                    : const Center(
                        child: CircularProgressIndicator(strokeWidth: 2)),
              ),
      );
}

class _ImageFrame extends StatelessWidget {
  final Widget child;
  final VoidCallback onRemove;
  const _ImageFrame({required this.child, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 108,
      height: 108,
      margin: const EdgeInsets.only(right: 12),
      child: Stack(fit: StackFit.expand, children: [
        ClipRRect(borderRadius: BorderRadius.circular(10), child: child),
        Positioned(
          right: 2,
          top: 2,
          child: Material(
            color: Colors.black54,
            shape: const CircleBorder(),
            child: InkWell(
              onTap: onRemove,
              customBorder: const CircleBorder(),
              child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(Icons.close, size: 16, color: Colors.white)),
            ),
          ),
        ),
      ]),
    );
  }
}
