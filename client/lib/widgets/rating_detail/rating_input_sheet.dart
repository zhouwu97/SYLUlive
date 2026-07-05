import 'package:flutter/material.dart';
import 'ranking_tokens.dart';

Future<void> showRatingInputSheet({
  required BuildContext context,
  required int initialStar,
  required String initialComment,
  required Future<bool> Function(int, String) onSubmit,
  required String title,
  int maxCommentLength = 500,
  Color? accentOverride,
}) async {
  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => _RatingInputSheet(
      initialStar: initialStar,
      initialComment: initialComment,
      onSubmit: onSubmit,
      title: title,
      maxCommentLength: maxCommentLength,
      accentOverride: accentOverride,
    ),
  );
}

class _RatingInputSheet extends StatefulWidget {
  final int initialStar;
  final String initialComment;
  final Future<bool> Function(int, String) onSubmit;
  final String title;
  final int maxCommentLength;
  final Color? accentOverride;

  const _RatingInputSheet({
    required this.initialStar,
    required this.initialComment,
    required this.onSubmit,
    required this.title,
    required this.maxCommentLength,
    this.accentOverride,
  });

  @override
  State<_RatingInputSheet> createState() => _RatingInputSheetState();
}

class _RatingInputSheetState extends State<_RatingInputSheet> {
  late int _star;
  late TextEditingController _commentCtrl;
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    _star = widget.initialStar;
    _commentCtrl = TextEditingController(text: widget.initialComment);
  }

  @override
  void dispose() {
    _commentCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = widget.accentOverride ?? RankingTokens.teacherAccent(isDark);
    final viewInsets = MediaQuery.of(context).viewInsets;

    return Container(
      margin: EdgeInsets.only(top: MediaQuery.of(context).padding.top + 20),
      decoration: BoxDecoration(
        color: RankingTokens.cardBg(isDark),
        borderRadius:
            const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: viewInsets.bottom > 0
            ? viewInsets.bottom + 16
            : MediaQuery.of(context).padding.bottom + 16,
      ),
      child: SingleChildScrollView(
        physics: const ClampingScrollPhysics(),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  widget.title,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: RankingTokens.titleColor(isDark),
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: List.generate(
                  5,
                  (i) => GestureDetector(
                    onTap: () => setState(() => _star = i + 1),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Icon(
                        i < _star ? Icons.star : Icons.star_border,
                        size: 40,
                        color: i < _star ? Colors.amber : Colors.grey[400],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _commentCtrl,
              maxLength: widget.maxCommentLength,
              maxLines: 4,
              minLines: 3,
              autofocus: true,
              decoration: InputDecoration(
                hintText: '写下你的评价...',
                hintStyle: TextStyle(
                  color: RankingTokens.subColor(isDark),
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                filled: true,
                fillColor: isDark
                    ? const Color(0x33FFFFFF)
                    : const Color(0x0A000000),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
              ),
              style: TextStyle(
                fontSize: 15,
                color: RankingTokens.titleColor(isDark),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 46,
              child: ElevatedButton(
                onPressed: _star == 0 || _isSubmitting
                    ? null
                    : () async {
                        setState(() => _isSubmitting = true);
                        final success = await widget.onSubmit(
                            _star, _commentCtrl.text.trim());
                        if (!context.mounted) return;
                        setState(() => _isSubmitting = false);
                        if (success) Navigator.pop(context);
                      },
                style: ElevatedButton.styleFrom(
                  backgroundColor: accent,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: _isSubmitting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : const Text(
                        '提交评价',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w700),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
