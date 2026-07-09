import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

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

  late String _title;
  late String _summary;
  late String _description;
  late String _categorySlug;
  late String _recommendationLevel;
  late String _schoolRecognitionStatus;
  late String _competitionLevel;
  late String _organizer;
  late String _registrationStart;
  late String _registrationEnd;
  late String _eventStart;
  late String _eventEnd;
  late String _timeNote;
  late String _officialUrl;
  late String _noticeUrl;
  late String _sourceNote;

  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    final d = widget.initialData ?? {};
    _title = d['title'] ?? '';
    _summary = d['summary'] ?? '';
    _description = d['description'] ?? '';
    _categorySlug = d['primary_category_slug'] ?? 'innovation_startup';
    _recommendationLevel = d['recommendation_level'] ?? 'B';
    _schoolRecognitionStatus = d['school_recognition_status'] ?? 'pending';
    _competitionLevel = d['competition_level'] ?? '省级';
    _organizer = d['organizer'] ?? '';
    _registrationStart = d['registration_start'] ?? '';
    _registrationEnd = d['registration_end'] ?? '';
    _eventStart = d['event_start'] ?? '';
    _eventEnd = d['event_end'] ?? '';
    _timeNote = d['time_note'] ?? '';
    _officialUrl = d['official_url'] ?? '';
    _noticeUrl = d['notice_url'] ?? '';
    _sourceNote = d['source_note'] ?? 'admin_manual';
  }

  Future<void> _submit(String status) async {
    if (!_formKey.currentState!.validate()) return;
    _formKey.currentState!.save();

    setState(() => _isSubmitting = true);

    try {
      final payload = {
        'title': _title,
        'summary': _summary,
        'description': _description,
        'primary_category_slug': _categorySlug,
        'recommendation_level': _recommendationLevel,
        'school_recognition_status': _schoolRecognitionStatus,
        'competition_level': _competitionLevel,
        'organizer': _organizer,
        'registration_start': _registrationStart,
        'registration_end': _registrationEnd,
        'event_start': _eventStart,
        'event_end': _eventEnd,
        'time_note': _timeNote,
        'official_url': _officialUrl,
        'notice_url': _noticeUrl,
        'source_note': _sourceNote,
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
        await dio.post(
          '/admin/competitions/events',
          data: payload,
        );
        if (!mounted) return;
        AppFeedback.showSnackBar(
            context, status == 'draft' ? '已保存为草稿' : '发布成功');
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
      AppFeedback.showSnackBar(
        context,
        '发生错误：$e',
        isError: true,
      );
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = CompetitionUiTokens.pageBg(isDark);
    final primary = CompetitionUiTokens.accent(isDark);

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
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              initialValue: _title,
              decoration: const InputDecoration(labelText: '比赛名称 *'),
              validator: (v) => v!.isEmpty ? '必填' : null,
              onSaved: (v) => _title = v!.trim(),
            ),
            const SizedBox(height: 12),
            TextFormField(
              initialValue: _summary,
              decoration: const InputDecoration(labelText: '一句话简介'),
              onSaved: (v) => _summary = v!.trim(),
            ),
            const SizedBox(height: 12),
            TextFormField(
              initialValue: _description,
              decoration: const InputDecoration(labelText: '比赛说明'),
              maxLines: 3,
              onSaved: (v) => _description = v!.trim(),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: _categorySlug,
              decoration: const InputDecoration(labelText: '分类 *'),
              items: const [
                DropdownMenuItem(
                    value: 'innovation_startup', child: Text('创新创业')),
                DropdownMenuItem(value: 'computer_ai', child: Text('计算机与AI')),
                DropdownMenuItem(value: 'math_science', child: Text('数学与基础科学')),
                DropdownMenuItem(value: 'art_design', child: Text('艺术与设计')),
                DropdownMenuItem(
                    value: 'business_economics', child: Text('商管与经济')),
                DropdownMenuItem(
                    value: 'language_humanities', child: Text('语言与人文')),
              ],
              onChanged: (v) => setState(() => _categorySlug = v!),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: _recommendationLevel,
              decoration: const InputDecoration(labelText: '推荐等级'),
              items: const [
                DropdownMenuItem(value: 'S', child: Text('S级 - 极力推荐')),
                DropdownMenuItem(value: 'A', child: Text('A级 - 推荐')),
                DropdownMenuItem(value: 'B', child: Text('B级 - 普通')),
                DropdownMenuItem(value: 'C', child: Text('C级 - 谨慎参加')),
              ],
              onChanged: (v) => setState(() => _recommendationLevel = v!),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: _schoolRecognitionStatus,
              decoration: const InputDecoration(labelText: '学校认定状态'),
              items: const [
                DropdownMenuItem(value: 'recognized', child: Text('学校认定')),
                DropdownMenuItem(value: 'not_recognized', child: Text('学校不认定')),
                DropdownMenuItem(value: 'pending', child: Text('待认定/无通知')),
                DropdownMenuItem(value: 'unknown', child: Text('认定未知')),
              ],
              onChanged: (v) => setState(() => _schoolRecognitionStatus = v!),
            ),
            const SizedBox(height: 12),
            TextFormField(
              initialValue: _competitionLevel,
              decoration: const InputDecoration(labelText: '比赛级别 (如国家级)'),
              onSaved: (v) => _competitionLevel = v!.trim(),
            ),
            const SizedBox(height: 12),
            TextFormField(
              initialValue: _organizer,
              decoration: const InputDecoration(labelText: '主办方'),
              onSaved: (v) => _organizer = v!.trim(),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    initialValue: _registrationStart,
                    decoration:
                        const InputDecoration(labelText: '报名开始 (YYYY-MM-DD)'),
                    onSaved: (v) => _registrationStart = v!.trim(),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextFormField(
                    initialValue: _registrationEnd,
                    decoration:
                        const InputDecoration(labelText: '报名结束 (YYYY-MM-DD)'),
                    onSaved: (v) => _registrationEnd = v!.trim(),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    initialValue: _eventStart,
                    decoration:
                        const InputDecoration(labelText: '比赛开始 (YYYY-MM-DD)'),
                    onSaved: (v) => _eventStart = v!.trim(),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextFormField(
                    initialValue: _eventEnd,
                    decoration:
                        const InputDecoration(labelText: '比赛结束 (YYYY-MM-DD)'),
                    onSaved: (v) => _eventEnd = v!.trim(),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextFormField(
              initialValue: _timeNote,
              decoration: const InputDecoration(labelText: '时间说明 (如：往年参考)'),
              onSaved: (v) => _timeNote = v!.trim(),
            ),
            const SizedBox(height: 12),
            TextFormField(
              initialValue: _officialUrl,
              decoration: const InputDecoration(labelText: '官网链接'),
              onSaved: (v) => _officialUrl = v!.trim(),
            ),
            const SizedBox(height: 12),
            TextFormField(
              initialValue: _noticeUrl,
              decoration: const InputDecoration(labelText: '通知链接'),
              onSaved: (v) => _noticeUrl = v!.trim(),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _isSubmitting ? null : () => _submit('draft'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: const Text('保存到官方草稿'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed:
                        _isSubmitting ? null : () => _submit('published'),
                    style: FilledButton.styleFrom(
                      backgroundColor: primary,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: const Text('直接发布'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
