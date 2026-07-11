import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../providers/team_recruitment_provider.dart';
import '../../models/team_recruitment.dart';
import '../../widgets/water_team/team_deadline_picker.dart';

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
  final List<XFile> _images = [];
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
      setState(() => _images.addAll(images.take(9 - _images.length)));
    }
  }

  Future<void> _pickDeadline() async {
    final now = DateTime.now();
    final picked = await TeamDeadlinePicker.show(context,
        firstDate: DateTime(now.year, now.month, now.day),
        lastDate: DateTime(now.year + 2),
        initialDate: _deadline ?? now.add(const Duration(days: 7)),
        accentColor: const Color(0xFF6A64D8));
    if (picked != null && mounted) {
      setState(() =>
          _deadline = DateTime(picked.year, picked.month, picked.day, 23, 59));
    }
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final provider = context.read<TeamRecruitmentProvider>();
    final existing = widget.initialValue;
    final created = existing == null
        ? await provider.create(
            category: _category,
            title: _title.text.trim(),
            description: _description.text.trim(),
            neededCount: int.parse(_needed.text),
            roles: _roles,
            deadline: _deadline,
            images: _images,
          )
        : (await provider.updateRecruitment(
            recruitmentId: existing.id,
            category: _category,
            title: _title.text.trim(),
            description: _description.text.trim(),
            neededCount: int.parse(_needed.text),
            roles: _roles,
            deadline: _deadline,
          ))
            .data;
    if (!mounted) return;
    if (created == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(existing == null ? '发布失败，请检查网络后重试' : '保存失败，请检查输入后重试')));
      return;
    }
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final creating = context.watch<TeamRecruitmentProvider>().isCreating;
    return Scaffold(
      appBar:
          AppBar(title: Text(widget.initialValue == null ? '发起组队' : '编辑招募')),
      bottomNavigationBar: SafeArea(
          child: Padding(
              padding: const EdgeInsets.all(16),
              child: FilledButton(
                  onPressed: creating ? null : _submit,
                  child: Text(creating
                      ? '提交中…'
                      : widget.initialValue == null
                          ? '发布组队'
                          : '保存修改')))),
      body: Form(
          key: _formKey,
          child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                const Text('组队类型',
                    style: TextStyle(fontWeight: FontWeight.w800)),
                const SizedBox(height: 8),
                Wrap(
                    spacing: 8,
                    children: const [
                      ('竞赛', 'competition'),
                      ('项目', 'project'),
                      ('学习', 'study'),
                      ('活动', 'activity'),
                      ('其他', 'other')
                    ]
                        .map((item) => item)
                        .map((item) => ChoiceChip(
                            label: Text(item.$1),
                            selected: _category == item.$2,
                            onSelected: (_) =>
                                setState(() => _category = item.$2)))
                        .toList()),
                const SizedBox(height: 18),
                TextFormField(
                    controller: _title,
                    maxLength: 100,
                    decoration: const InputDecoration(
                        labelText: '组队标题',
                        hintText: '例如：数学建模国赛寻找队友',
                        border: OutlineInputBorder()),
                    validator: (v) =>
                        (v ?? '').trim().length < 2 ? '标题至少 2 个字' : null),
                const SizedBox(height: 14),
                TextFormField(
                    controller: _description,
                    maxLines: 6,
                    maxLength: 5000,
                    decoration: const InputDecoration(
                        labelText: '组队说明',
                        hintText: '介绍目标、已有成员、计划和要求',
                        border: OutlineInputBorder()),
                    validator: (v) =>
                        (v ?? '').trim().length < 10 ? '说明至少 10 个字' : null),
                const SizedBox(height: 14),
                TextFormField(
                    controller: _needed,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(
                        labelText: '还需人数', border: OutlineInputBorder()),
                    validator: (v) {
                      final n = int.tryParse(v ?? '');
                      return n == null || n < 1 || n > 20 ? '请输入 1～20 人' : null;
                    }),
                const SizedBox(height: 14),
                const Text('所需方向（可选）',
                    style: TextStyle(fontWeight: FontWeight.w800)),
                const SizedBox(height: 8),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  ..._roles.map((role) => InputChip(
                      label: Text(role),
                      onDeleted: () => setState(() => _roles.remove(role)))),
                  SizedBox(
                      width: 190,
                      child: TextField(
                          controller: _role,
                          onSubmitted: (_) => _addRole(),
                          decoration: InputDecoration(
                              hintText: '输入方向',
                              suffixIcon: IconButton(
                                  onPressed: _addRole,
                                  icon: const Icon(Icons.add))))),
                ]),
                const SizedBox(height: 14),
                ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.event_outlined),
                    title: Text(_deadline == null
                        ? '不设置截止日期'
                        : '截止 ${_deadline!.year}-${_deadline!.month.toString().padLeft(2, '0')}-${_deadline!.day.toString().padLeft(2, '0')}'),
                    trailing: TextButton(
                        onPressed: _pickDeadline, child: const Text('选择日期'))),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                    onPressed: _images.length >= 9 ? null : _pickImages,
                    icon: const Icon(Icons.photo_library_outlined),
                    label: Text('添加图片（${_images.length}/9）')),
                if (_images.isNotEmpty)
                  Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: _images
                              .asMap()
                              .entries
                              .map((entry) => Chip(
                                  label: Text('图片 ${entry.key + 1}'),
                                  onDeleted: () => setState(
                                      () => _images.removeAt(entry.key))))
                              .toList())),
              ])),
    );
  }
}
