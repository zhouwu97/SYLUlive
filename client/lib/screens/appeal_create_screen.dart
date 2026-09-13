import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../app_bootstrap.dart';
import '../utils/app_feedback.dart';
import '../widgets/app_page_app_bar.dart';
import 'court_screen.dart';

/// 治理通知进入的主动申诉页；提交时绑定具体 ReportID，避免误用历史举报。
class AppealCreateScreen extends StatefulWidget {
  final int reportId;
  final int? postId;
  final String governanceReason;

  const AppealCreateScreen({
    super.key,
    required this.reportId,
    this.postId,
    this.governanceReason = '',
  });

  @override
  State<AppealCreateScreen> createState() => _AppealCreateScreenState();
}

class _AppealCreateScreenState extends State<AppealCreateScreen> {
  late final TextEditingController _reasonController;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _reasonController = TextEditingController();
  }

  @override
  void dispose() {
    _reasonController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final reason = _reasonController.text.trim();
    if (reason.length < 2) {
      AppFeedback.showSnackBar(context, '请至少填写 2 个字的申诉理由', isError: true);
      return;
    }
    setState(() => _submitting = true);
    try {
      final response = await getSharedDio().post(
        '/appeals/report/${widget.reportId}',
        data: {'appellant_reason': reason},
      );
      final raw = response.data is Map ? response.data as Map : const {};
      final id = raw['id'] is num ? raw['id'] as num : null;
      if (!mounted) return;
      AppFeedback.showSnackBar(context, '申诉已提交，案件进入社区复核');
      if (id != null) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => CourtScreen(appealId: id.toInt())),
        );
      } else {
        Navigator.pop(context);
      }
    } on DioException catch (error) {
      if (mounted) {
        AppFeedback.showSnackBar(
          context,
          error.response?.data is Map
              ? (error.response?.data['error']?.toString() ?? '提交申诉失败')
              : '提交申诉失败',
          isError: true,
        );
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const AppPageAppBar(title: Text('申请社区复核')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          Text('原治理决定', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Theme.of(context).dividerColor),
            ),
            child: Text(widget.governanceReason.isEmpty
                ? '管理员已对你的内容作出处理。'
                : widget.governanceReason),
          ),
          const SizedBox(height: 24),
          Text('申诉理由', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          TextField(
            controller: _reasonController,
            minLines: 5,
            maxLines: 8,
            maxLength: 1000,
            textInputAction: TextInputAction.newline,
            decoration: const InputDecoration(
              hintText: '请说明你认为原处理不准确的原因，可补充事实和证据。',
              alignLabelWithHint: true,
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '提交后将随机邀请符合条件的社区成员陪审。陪审员身份和单票内容不会公开。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _submitting ? null : _submit,
            child: _submitting
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('提交申诉'),
          ),
        ],
      ),
    );
  }
}
