import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../config/api_constants.dart';
import '../../models/post.dart';
import '../../providers/team_recruitment_provider.dart';
import '../../models/team_recruitment.dart';
import '../../widgets/water_team/team_deadline_picker.dart';
import '../../widgets/team/team_form_section.dart';
import '../../widgets/team/team_ui_tokens.dart';
import '../../widgets/app_cached_image.dart';

class TeamRecruitmentCreateScreen extends StatefulWidget {
  final TeamRecruitment? initialValue;
  const TeamRecruitmentCreateScreen({super.key, this.initialValue});

  @override
  State<TeamRecruitmentCreateScreen> createState() =>
      _TeamRecruitmentCreateScreenState();
}

class _TeamRecruitmentCreateScreenState
    extends State<TeamRecruitmentCreateScreen> {
  final _formKey = GlobalKey<FormState>();
  final _title = TextEditingController();
  final _description = TextEditingController();
  final _needed = TextEditingController(text: '1');
  final _role = TextEditingController();
  final List<String> _roles = [];
  final List<PostImage> _existingImages = [];
  final List<XFile> _images = [];
  bool _imagesChanged = false;
  String _category = 'competition';
  DateTime? _deadline;

  @override
  void initState() {
    super.initState();
    final value = widget.initialValue;
    if (value != null) {
      _title.text = value.title;
      _description.text = value.description;
      _needed.text = value.neededCount.toString();
      _roles.addAll(value.roles);
      _existingImages.addAll(value.images);
      _category = value.category;
      _deadline = value.deadline;
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    _needed.dispose();
    _role.dispose();
    super.dispose();
  }

  void _addRole() {
    final value = _role.text.trim();
    if (value.isEmpty || _roles.contains(value)) return;
    if (value.length > 20 || _roles.length >= 8) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('方向最多 8 项，每项不超过 20 字')));
      return;
    }
    setState(() {
      _roles.add(value);
      _role.clear();
    });
  }

  Future<void> _pickImages() async {
    final images = await ImagePicker().pickMultiImage(imageQuality: 88);
    if (images.isNotEmpty && mounted) {
      final remaining = 9 - _existingImages.length - _images.length;
      if (remaining <= 0) return;
      setState(() {
        _images.addAll(images.take(remaining));
        _imagesChanged = true;
      });
    }
  }

  Future<void> _pickDeadline() async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final initialDate = _deadline != null && !_deadline!.isBefore(today)
        ? _deadline!
        : now.add(const Duration(days: 7));
    final picked = await TeamDeadlinePicker.show(context,
        firstDate: today,
        lastDate: DateTime(now.year + 2),
        initialDate: initialDate,
        accentColor: TeamUiTokens.accent(isDark));
    if (picked != null && mounted) {
      setState(() =>
          _deadline = DateTime(picked.year, picked.month, picked.day, 23, 59));
    }
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final provider = context.read<TeamRecruitmentProvider>();
    final existing = widget.initialValue;
    if (existing == null) {
      final created = await provider.create(
        category: _category,
        title: _title.text.trim(),
        description: _description.text.trim(),
        neededCount: int.parse(_needed.text),
        roles: _roles,
        deadline: _deadline,
        images: _images,
      );
      if (!mounted) return;
      if (created == null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('发布失败，请检查网络后重试')));
        return;
      }
      Navigator.pop(context, true);
      return;
    }

    final result = await provider.updateRecruitment(
      recruitmentId: existing.id,
      category: _category,
      title: _title.text.trim(),
      description: _description.text.trim(),
      neededCount: int.parse(_needed.text),
      roles: _roles,
      deadline: _deadline,
      imageFileIds: _imagesChanged
          ? _existingImages
              .map((image) => image.fileId)
              .where((fileId) => fileId > 0)
              .toList()
          : null,
      images: _images,
    );
    if (!mounted) return;
    if (!result.success) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(result.errorMessage ?? '保存失败，请稍后重试')));
      return;
    }
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<TeamRecruitmentProvider>();
    final submitting = provider.isCreating ||
        (widget.initialValue != null &&
            provider.updatingIds.contains(widget.initialValue!.id));
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final pageColor = TeamUiTokens.pageBg(isDark);
    final borderColor = TeamUiTokens.border(isDark);

    final inputDecoration = InputDecoration(
      filled: true,
      fillColor: Colors.transparent,
      border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(TeamUiTokens.fieldRadius),
          borderSide: BorderSide(color: borderColor)),
      enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(TeamUiTokens.fieldRadius),
          borderSide: BorderSide(color: borderColor)),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(TeamUiTokens.fieldRadius),
          borderSide:
              BorderSide(color: TeamUiTokens.accent(isDark), width: 1.5)),
    );

    return Scaffold(
      backgroundColor: pageColor,
      appBar: AppBar(
        backgroundColor: pageColor,
        surfaceTintColor: Colors.transparent,
        title: Text(widget.initialValue == null ? '发起组队' : '编辑招募'),
      ),
      bottomNavigationBar: DecoratedBox(
        decoration: BoxDecoration(
          color: pageColor,
          border: Border(top: BorderSide(color: borderColor)),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
            child: SizedBox(
              height: 48,
              child: FilledButton(
                style: TeamUiTokens.primaryButtonStyle(isDark),
                onPressed: submitting ? null : _submit,
                child: Text(submitting
                    ? '提交中…'
                    : (widget.initialValue == null ? '发布组队' : '保存修改')),
              ),
            ),
          ),
        ),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            const Text(
              '告诉大家你想组建什么队伍\n信息写得越清楚，越容易找到合适的队友',
              style: TextStyle(fontSize: 13, color: Colors.grey, height: 1.4),
            ),
            const SizedBox(height: TeamUiTokens.sectionGap),
            TeamFormSection(
              title: '基础信息',
              children: [
                const Text('组队类型',
                    style:
                        TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: const [
                    ('竞赛', 'competition'),
                    ('项目', 'project'),
                    ('学习', 'study'),
                    ('活动', 'activity'),
                    ('其他', 'other')
                  ].map((item) {
                    final selected = _category == item.$2;
                    return ChoiceChip(
                      label: Text(item.$1),
                      selected: selected,
                      selectedColor: TeamUiTokens.accentSoft(isDark),
                      labelStyle: TextStyle(
                        color: selected
                            ? TeamUiTokens.accent(isDark)
                            : TeamUiTokens.subtitle(isDark),
                        fontWeight:
                            selected ? FontWeight.w700 : FontWeight.w400,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: BorderSide(
                            color: selected ? Colors.transparent : borderColor),
                      ),
                      onSelected: (_) => setState(() => _category = item.$2),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 14),
                const Text('组队标题',
                    style:
                        TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _title,
                  maxLength: 100,
                  cursorColor: TeamUiTokens.accent(isDark),
                  decoration:
                      inputDecoration.copyWith(hintText: '例如：数学建模国赛寻找队友'),
                  validator: (v) =>
                      (v ?? '').trim().length < 2 ? '标题至少 2 个字' : null,
                ),
                const SizedBox(height: 14),
                const Text('组队说明',
                    style:
                        TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _description,
                  maxLines: 6,
                  maxLength: 5000,
                  cursorColor: TeamUiTokens.accent(isDark),
                  decoration:
                      inputDecoration.copyWith(hintText: '介绍参赛目标、已有成员和计划……'),
                  validator: (v) =>
                      (v ?? '').trim().length < 10 ? '说明至少 10 个字' : null,
                ),
              ],
            ),
            const SizedBox(height: TeamUiTokens.sectionGap),
            TeamFormSection(
              title: '招募要求',
              children: [
                Row(
                  children: [
                    const Expanded(
                        child: Text('计划招募总人数', style: TextStyle(fontSize: 15))),
                    IconButton(
                      onPressed: int.parse(_needed.text) > 1
                          ? () => setState(() => _needed.text =
                              (int.parse(_needed.text) - 1).toString())
                          : null,
                      icon: Icon(Icons.remove,
                          color: TeamUiTokens.accent(isDark)),
                    ),
                    Text(_needed.text, style: const TextStyle(fontSize: 16)),
                    IconButton(
                      onPressed: int.parse(_needed.text) < 20
                          ? () => setState(() => _needed.text =
                              (int.parse(_needed.text) + 1).toString())
                          : null,
                      icon: Icon(Icons.add, color: TeamUiTokens.accent(isDark)),
                    ),
                  ],
                ),
                if (widget.initialValue != null)
                  Text(
                    '当前已加入 ${widget.initialValue!.acceptedCount} 人，修改后还缺 ${(int.parse(_needed.text) - widget.initialValue!.acceptedCount).clamp(0, 20)} 人',
                    style: TextStyle(
                        fontSize: 12, color: TeamUiTokens.subtitle(isDark)),
                  ),
                Divider(color: borderColor),
                const SizedBox(height: 8),
                const Row(
                  children: [
                    Expanded(
                        child: Text('所需方向', style: TextStyle(fontSize: 15))),
                    Icon(Icons.chevron_right, size: 20, color: Colors.grey),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  ..._roles.map((role) => InputChip(
                      label: Text(role),
                      onDeleted: () => setState(() => _roles.remove(role)))),
                  SizedBox(
                      width: 150,
                      height: 36,
                      child: TextField(
                          controller: _role,
                          onSubmitted: (_) => _addRole(),
                          cursorColor: TeamUiTokens.accent(isDark),
                          decoration: InputDecoration(
                            hintText: '+ 添加方向',
                            hintStyle: TextStyle(
                                color: TeamUiTokens.accent(isDark),
                                fontSize: 13),
                            contentPadding:
                                const EdgeInsets.symmetric(horizontal: 10),
                            border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: BorderSide(color: borderColor)),
                            enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: BorderSide(color: borderColor)),
                            focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: BorderSide(
                                    color: TeamUiTokens.accent(isDark))),
                          ))),
                ]),
              ],
            ),
            const SizedBox(height: TeamUiTokens.sectionGap),
            TeamFormSection(
              title: '补充信息',
              children: [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('截止时间', style: TextStyle(fontSize: 15)),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_deadline != null)
                        IconButton(
                          tooltip: '清除截止时间',
                          visualDensity: VisualDensity.compact,
                          onPressed: () => setState(() => _deadline = null),
                          icon: const Icon(Icons.close_rounded, size: 18),
                        ),
                      Text(
                        _deadline == null
                            ? '不设置'
                            : '${_deadline!.year}-${_deadline!.month.toString().padLeft(2, '0')}-${_deadline!.day.toString().padLeft(2, '0')}',
                        style: TextStyle(color: TeamUiTokens.subtitle(isDark)),
                      ),
                      const SizedBox(width: 4),
                      const Icon(Icons.chevron_right,
                          size: 20, color: Colors.grey),
                    ],
                  ),
                  onTap: _pickDeadline,
                ),
                Divider(color: borderColor),
                const SizedBox(height: 8),
                const Text('相关图片', style: TextStyle(fontSize: 15)),
                const SizedBox(height: 12),
                GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                  ),
                  itemCount: _existingImages.length + _images.length < 9
                      ? _existingImages.length + _images.length + 1
                      : 9,
                  itemBuilder: (_, index) {
                    final totalImages = _existingImages.length + _images.length;
                    if (index == 0 && totalImages < 9) {
                      return InkWell(
                        onTap: _pickImages,
                        borderRadius: BorderRadius.circular(10),
                        child: Container(
                          decoration: BoxDecoration(
                            border: Border.all(color: borderColor),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.add_rounded,
                                  color: TeamUiTokens.accent(isDark)),
                              const SizedBox(height: 4),
                              Text('添加',
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: TeamUiTokens.subtitle(isDark))),
                            ],
                          ),
                        ),
                      );
                    }
                    final imageIndex = totalImages < 9 ? index - 1 : index;
                    final isExisting = imageIndex < _existingImages.length;
                    final existingImage =
                        isExisting ? _existingImages[imageIndex] : null;
                    final newImageIndex = imageIndex - _existingImages.length;
                    return ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Stack(fit: StackFit.expand, children: [
                        if (existingImage != null)
                          AppCachedImage.public(
                            imageUrl: ApiConstants.fullUrl(existingImage.url),
                            fit: BoxFit.cover,
                            memCacheWidth: 512,
                            memCacheHeight: 512,
                            errorWidget: (_, __, ___) => const ColoredBox(
                              color: Color(0xFFE8ECEA),
                              child: Icon(Icons.broken_image_outlined),
                            ),
                          )
                        else
                          Image.file(File(_images[newImageIndex].path),
                              fit: BoxFit.cover),
                        Align(
                          alignment: Alignment.topRight,
                          child: IconButton.filledTonal(
                            tooltip: '删除图片',
                            icon: const Icon(Icons.close_rounded, size: 18),
                            onPressed: () => setState(() {
                              if (isExisting) {
                                _existingImages.removeAt(imageIndex);
                              } else {
                                _images.removeAt(newImageIndex);
                              }
                              _imagesChanged = true;
                            }),
                          ),
                        ),
                      ]),
                    );
                  },
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              '提示：联系方式无需直接写在正文中，\n申请通过后可通过站内私信联系。',
              style:
                  TextStyle(fontSize: 12, color: TeamUiTokens.subtitle(isDark)),
            ),
          ],
        ),
      ),
    );
  }
}
