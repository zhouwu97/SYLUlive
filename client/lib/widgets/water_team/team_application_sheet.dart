import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/post.dart';
import '../../providers/water_team_provider.dart';

/// 申请加入组队招募的轻量底部表单。
///
/// 返回操作后最新的 [Post]，供详情页直接更新；失败返回 `null`。
class TeamApplicationSheet extends StatefulWidget {
  final int recruitmentId;

  const TeamApplicationSheet({
    super.key,
    required this.recruitmentId,
  });

  /// 弹出申请表单。返回最新 [Post] 或 `null`（取消/失败）。
  static Future<Post?> show(
    BuildContext context, {
    required int recruitmentId,
  }) {
    return showModalBottomSheet<Post?>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => TeamApplicationSheet(
        recruitmentId: recruitmentId,
      ),
    );
  }

  @override
  State<TeamApplicationSheet> createState() => _TeamApplicationSheetState();
}

class _TeamApplicationSheetState extends State<TeamApplicationSheet> {
  final _formKey = GlobalKey<FormState>();
  final _messageController = TextEditingController();
  final _availabilityController = TextEditingController();

  @override
  void dispose() {
    _messageController.dispose();
    _availabilityController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final provider = context.read<WaterTeamProvider>();
    final result = await provider.apply(
      recruitmentId: widget.recruitmentId,
      message: _messageController.text.trim(),
      availability: _availabilityController.text.trim(),
    );
    if (!mounted) return;
    if (result != null) {
      Navigator.of(context).pop(null);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('申请已提交')),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(
                provider.errorFor(widget.recruitmentId) ?? '申请提交失败')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final processing = context
        .watch<WaterTeamProvider>()
        .isRecruitmentProcessing(widget.recruitmentId);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        4,
        20,
        20 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('申请加入',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            Text('请简单介绍你的经验和想参与的工作。',
                style: TextStyle(color: Colors.grey.shade600)),
            const SizedBox(height: 16),
            TextFormField(
              controller: _messageController,
              minLines: 4,
              maxLines: 7,
              maxLength: 500,
              decoration: const InputDecoration(
                labelText: '申请留言（必填）',
                hintText: '介绍一下你的经验、擅长内容，以及想参与的工作',
                border: OutlineInputBorder(),
              ),
              validator: (value) {
                final length = value?.trim().length ?? 0;
                if (length < 5) return '申请留言至少 5 个字';
                if (length > 500) return '申请留言最多 500 个字';
                return null;
              },
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: _availabilityController,
              maxLines: 3,
              maxLength: 200,
              decoration: const InputDecoration(
                labelText: '可参与时间（选填）',
                hintText: '例如：工作日晚间、周末全天',
                border: OutlineInputBorder(),
              ),
              validator: (value) =>
                  (value?.length ?? 0) > 200 ? '最多 200 个字' : null,
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              height: 46,
              child: FilledButton(
                onPressed: processing ? null : _submit,
                child: processing
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('确认申请',
                        style: TextStyle(fontWeight: FontWeight.w800)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
