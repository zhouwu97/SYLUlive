import 'package:flutter/material.dart';

import 'team_ui_tokens.dart';

typedef TeamApplicationDraft = ({String message, String availability});

/// 展示组队申请表单，并在本地校验通过后返回待提交内容。
class TeamRecruitmentApplicationSheet extends StatefulWidget {
  const TeamRecruitmentApplicationSheet({super.key});

  static Future<TeamApplicationDraft?> show(BuildContext context) {
    return showModalBottomSheet<TeamApplicationDraft>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => const TeamRecruitmentApplicationSheet(),
    );
  }

  @override
  State<TeamRecruitmentApplicationSheet> createState() =>
      _TeamRecruitmentApplicationSheetState();
}

class _TeamRecruitmentApplicationSheetState
    extends State<TeamRecruitmentApplicationSheet> {
  final _formKey = GlobalKey<FormState>();
  final _messageController = TextEditingController();
  final _availabilityController = TextEditingController();

  @override
  void dispose() {
    _messageController.dispose();
    _availabilityController.dispose();
    super.dispose();
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    Navigator.pop(context, (
      message: _messageController.text.trim(),
      availability: _availabilityController.text.trim(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final borderColor = TeamUiTokens.border(isDark);
    final inputDecoration = InputDecoration(
      filled: true,
      fillColor: Colors.transparent,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: borderColor),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: borderColor),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(
          color: TeamUiTokens.accent(isDark),
          width: 1.5,
        ),
      ),
    );

    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        20,
        20,
        MediaQuery.viewInsetsOf(context).bottom + 20,
      ),
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '申请加入',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: TeamUiTokens.title(isDark),
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _messageController,
              maxLines: 4,
              maxLength: 500,
              cursorColor: TeamUiTokens.accent(isDark),
              autovalidateMode: AutovalidateMode.onUserInteraction,
              validator: (value) {
                final length = value?.trim().length ?? 0;
                if (length < 5) return '申请说明至少 5 个字';
                if (length > 500) return '申请说明最多 500 个字';
                return null;
              },
              decoration: inputDecoration.copyWith(
                labelText: '申请说明 *',
                hintText: '介绍你的经验、能力和加入原因',
              ),
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: _availabilityController,
              maxLines: 2,
              maxLength: 200,
              cursorColor: TeamUiTokens.accent(isDark),
              validator: (value) =>
                  (value?.length ?? 0) > 200 ? '最多 200 个字' : null,
              decoration: inputDecoration.copyWith(
                labelText: '可参与时间（选填）',
                hintText: '例如：工作日晚 7 点后，周末全天',
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: FilledButton(
                style: TeamUiTokens.primaryButtonStyle(isDark),
                onPressed: _submit,
                child: const Text('提交申请'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
