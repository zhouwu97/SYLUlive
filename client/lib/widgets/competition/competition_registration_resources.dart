import 'package:flutter/material.dart';

import '../../models/competition.dart';
import '../../platform/contracts/external_navigator.dart';
import '../../utils/app_feedback.dart';
import 'competition_ui_tokens.dart';

/// 官网只作为信息来源，不把链接或收藏计划误称为报名成功。
class CompetitionRegistrationResources extends StatelessWidget {
  const CompetitionRegistrationResources({super.key, required this.event});

  final CompetitionEvent event;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final links = <(String, Uri)>[];
    final seen = <String>{};
    void addLink(String label, String value) {
      final uri = Uri.tryParse(value.trim());
      if (uri == null ||
          !{'http', 'https'}.contains(uri.scheme) ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          !seen.add(uri.toString())) {
        return;
      }
      links.add((label, uri));
    }

    addLink('查看通知', event.noticeUrl);
    addLink('打开官网', event.officialUrl);
    for (var index = 0; index < event.attachmentUrls.length; index++) {
      addLink('查看附件 ${index + 1}', event.attachmentUrls[index]);
    }

    final hasNotice = links.any((link) => link.$1 == '查看通知');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          hasNotice
              ? '请核对通知的适用届次、赛道和校内报名要求，再按通知完成报名。'
              : '当届报名通知待补充，校内选拔、报名步骤和材料要求尚需确认。',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: CompetitionUiTokens.titleColor(isDark),
              ),
        ),
        if (links.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '官网和附件暂未提供，可关注学校或主办方后续通知。',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: CompetitionUiTokens.subColor(isDark),
                  ),
            ),
          ),
        for (final (label, uri) in links)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: OutlinedButton(
              onPressed: () => _open(context, uri),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(44, 44),
                foregroundColor: CompetitionUiTokens.titleColor(isDark),
                side:
                    BorderSide(color: CompetitionUiTokens.borderColor(isDark)),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    const Icon(Icons.open_in_new, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(label),
                          Text(
                            uri.host,
                            style: Theme.of(context).textTheme.bodySmall,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        const SizedBox(height: 8),
        Text(
          '加入计划仅用于个人安排，不代表已完成报名。',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: CompetitionUiTokens.subColor(isDark),
              ),
        ),
      ],
    );
  }

  Future<void> _open(BuildContext context, Uri uri) async {
    try {
      if (await ExternalNavigator.current().open(uri)) return;
    } catch (_) {
      // 平台未安装可处理链接的应用时也提供明确反馈。
    }
    if (context.mounted) {
      AppFeedback.showSnackBar(context, '链接暂时无法打开，请稍后重试', isError: true);
    }
  }
}
