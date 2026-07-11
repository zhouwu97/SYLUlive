import 'package:flutter/material.dart';

class ExamPaperUploadStepHeader extends StatelessWidget {
  final bool infoCompleted;
  final bool fileCompleted;
  final bool privacyCompleted;
  final bool submitting;

  const ExamPaperUploadStepHeader({
    super.key,
    required this.infoCompleted,
    required this.fileCompleted,
    required this.privacyCompleted,
    required this.submitting,
  });

  @override
  Widget build(BuildContext context) {
    final completed = [
      infoCompleted,
      fileCompleted,
      privacyCompleted,
      submitting,
    ];
    const labels = ['填写信息', '选择文件', '隐私确认', '提交'];
    return Row(
      children: [
        for (var index = 0; index < labels.length; index++) ...[
          Expanded(
            child: Column(
              children: [
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: completed[index]
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).colorScheme.surfaceContainerHighest,
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: completed[index]
                      ? Icon(
                          Icons.check,
                          size: 16,
                          color: Theme.of(context).colorScheme.onPrimary,
                        )
                      : Text('${index + 1}'),
                ),
                const SizedBox(height: 5),
                Text(
                  labels[index],
                  maxLines: 1,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          if (index < labels.length - 1)
            Container(
              width: 14,
              height: 1,
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
        ],
      ],
    );
  }
}
