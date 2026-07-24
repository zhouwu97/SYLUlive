import 'package:flutter/material.dart';
import 'ranking_tokens.dart';

Future<void> showRatingReportSheet({
  required BuildContext context,
  required String targetType,
  required int targetId,
  required Future<bool> Function(String reasonCode, String description)
      onSubmit,
}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor:
        RankingTokens.pageBg(Theme.of(context).brightness == Brightness.dark),
    builder: (ctx) => _RatingReportSheet(
      onSubmit: onSubmit,
    ),
  );
}

class _RatingReportSheet extends StatefulWidget {
  final Future<bool> Function(String reasonCode, String description) onSubmit;

  const _RatingReportSheet({required this.onSubmit});

  @override
  State<_RatingReportSheet> createState() => _RatingReportSheetState();
}

class _RatingReportSheetState extends State<_RatingReportSheet> {
  String? _selectedReason;
  final TextEditingController _descController = TextEditingController();
  bool _isSubmitting = false;

  final Map<String, String> _reasons = {
    'spam': '垃圾广告或无意义内容',
    'abuse': '人身攻击、辱骂或歧视',
    'privacy': '泄露他人隐私',
    'false': '捏造事实、恶意造谣',
    'other': '其他违规内容',
  };

  Future<void> _submit() async {
    if (_selectedReason == null) return;

    final desc = _descController.text.trim();
    if (_selectedReason == 'other' && desc.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请填写具体的举报说明')),
      );
      return;
    }

    setState(() => _isSubmitting = true);

    final success = await widget.onSubmit(_selectedReason!, desc);

    if (mounted) {
      setState(() => _isSubmitting = false);
      if (success) {
        Navigator.pop(context);
      }
    }
  }

  @override
  void dispose() {
    _descController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
        left: 16,
        right: 16,
        top: 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '举报该评价',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: RankingTokens.titleColor(isDark),
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          Text(
            '请选择举报原因',
            style: TextStyle(
              fontSize: 14,
              color: RankingTokens.subColor(isDark),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _reasons.entries.map((e) {
              final isSelected = _selectedReason == e.key;
              return ChoiceChip(
                label: Text(e.value),
                selected: isSelected,
                onSelected: (selected) {
                  if (selected) {
                    setState(() => _selectedReason = e.key);
                  }
                },
                selectedColor: isDark ? Colors.white24 : Colors.black12,
                labelStyle: TextStyle(
                  color: isSelected
                      ? RankingTokens.titleColor(isDark)
                      : RankingTokens.subColor(isDark),
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _descController,
            maxLines: 3,
            maxLength: 500,
            decoration: InputDecoration(
              hintText:
                  _selectedReason == 'other' ? '必填：请详细描述违规情况...' : '选填：补充说明',
              hintStyle: TextStyle(color: RankingTokens.mutedColor(isDark)),
              filled: true,
              fillColor: isDark
                  ? Colors.white10
                  : Colors.black.withValues(alpha: 0.04),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.all(12),
            ),
            style: TextStyle(color: RankingTokens.titleColor(isDark)),
          ),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed:
                (_selectedReason != null && !_isSubmitting) ? _submit : null,
            style: ElevatedButton.styleFrom(
              backgroundColor: RankingTokens.teacherAccent(isDark),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: _isSubmitting
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : const Text('提交举报',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
