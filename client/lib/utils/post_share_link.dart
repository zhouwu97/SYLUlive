import 'package:flutter/widgets.dart';
import 'package:share_plus/share_plus.dart';

import '../models/post.dart';
import 'app_feedback.dart';
import 'team_share_link.dart';

Future<void> sharePostLink(BuildContext context, Post post) async {
  // Web 投票详情按投票 ID 读取，同一条帖子的帖子 ID 与投票 ID 可以不同。
  final pollId = post.pollMeta?.id ?? 0;
  final path = pollId > 0 ? '/web/polls/$pollId' : '/web/post/${post.id}';
  final link = Uri.https(TeamShareLink.domain, path);
  final box = context.findRenderObject() as RenderBox;
  try {
    await Share.share(
      link.toString(),
      sharePositionOrigin: box.localToGlobal(Offset.zero) & box.size,
    );
  } catch (_) {
    if (context.mounted) {
      AppFeedback.error('分享失败，请稍后重试', context: context);
    }
  }
}
