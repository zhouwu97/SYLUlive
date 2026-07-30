import 'package:flutter/material.dart';

import '../../models/competition.dart';
import 'competition_ui_tokens.dart';

Future<void> showCompetitionMatchReasonSheet(
  BuildContext context,
  CompetitionEvent event,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => CompetitionMatchReasonSheet(event: event),
  );
}

class CompetitionMatchReasonSheet extends StatelessWidget {
  final CompetitionEvent event;

  const CompetitionMatchReasonSheet({super.key, required this.event});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final dimensions = event.matchDimensions;
    final rows = <(String, String)>[
      ('参赛资格', _dimensionLabel(dimensions.eligibility)),
      ('专业方向', _dimensionLabel(dimensions.major)),
      ('学院范围', _dimensionLabel(dimensions.college)),
      ('年级要求', _dimensionLabel(dimensions.grade)),
      ('目标方向', _dimensionLabel(dimensions.goal)),
      ('技能基础', _dimensionLabel(dimensions.skill)),
      ('时间投入', _dimensionLabel(dimensions.time)),
      (
        '赛事证据',
        event.evidenceSubgrade.trim().isEmpty
            ? '待确认'
            : event.evidenceSubgrade.trim(),
      ),
    ];
    return SafeArea(
      top: false,
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .84,
        ),
        decoration: BoxDecoration(
          color: CompetitionUiTokens.pageBg(isDark),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: CompetitionUiTokens.borderColor(isDark),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '为什么进入候选',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: CompetitionUiTokens.titleColor(isDark),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              Text(
                event.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: CompetitionUiTokens.subColor(isDark),
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 18),
              for (final row in rows)
                _ReasonRow(label: row.$1, value: row.$2, isDark: isDark),
              if (event.cautions.isNotEmpty) ...[
                _sectionTitle('需要注意', isDark),
                for (final caution in event.cautions) _bullet(caution, isDark),
              ],
              if (event.questionsToConfirm.isNotEmpty) ...[
                _sectionTitle('待确认', isDark),
                for (final question in event.questionsToConfirm)
                  _bullet(question, isDark),
              ],
              _sectionTitle('数据依据', isDark),
              _ReasonRow(
                label: '目录版本',
                value: event.datasetVersion.trim().isEmpty
                    ? 'legacy'
                    : event.datasetVersion.trim(),
                isDark: isDark,
              ),
              _ReasonRow(
                label: '赛事编号',
                value: event.competitionId.trim().isEmpty
                    ? '待补充'
                    : event.competitionId.trim(),
                isDark: isDark,
              ),
              _ReasonRow(
                label: '更新时间',
                value: _dateLabel(event.updatedAt),
                isDark: isDark,
              ),
              const SizedBox(height: 14),
              Text(
                '当前结果用于候选筛选与解释，不代表获奖概率。',
                style: TextStyle(
                  color: CompetitionUiTokens.subColor(isDark),
                  fontSize: 12,
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionTitle(String text, bool isDark) {
    return Padding(
      padding: const EdgeInsets.only(top: 18, bottom: 8),
      child: Text(
        text,
        style: TextStyle(
          fontWeight: FontWeight.w800,
          color: CompetitionUiTokens.titleColor(isDark),
        ),
      ),
    );
  }

  Widget _bullet(String text, bool isDark) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '• ',
            style: TextStyle(color: CompetitionUiTokens.subColor(isDark)),
          ),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: CompetitionUiTokens.titleColor(isDark),
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ReasonRow extends StatelessWidget {
  final String label;
  final String value;
  final bool isDark;

  const _ReasonRow({
    required this.label,
    required this.value,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 82,
            child: Text(
              label,
              style: TextStyle(color: CompetitionUiTokens.subColor(isDark)),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: CompetitionUiTokens.titleColor(isDark),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _dimensionLabel(String value) {
  switch (value.trim()) {
    case 'matched':
      return '符合';
    case 'partial':
    case 'partially_matched':
      return '部分匹配';
    case 'unmatched':
      return '不符合';
    case 'unrestricted':
      return '不限';
    default:
      return '尚未确认';
  }
}

String _dateLabel(DateTime? value) {
  if (value == null) return '待确认';
  return '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';
}
