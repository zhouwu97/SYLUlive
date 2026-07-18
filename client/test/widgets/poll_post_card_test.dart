import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/poll.dart';
import 'package:shenliyuan/models/post.dart';
import 'package:shenliyuan/providers/poll_provider.dart';
import 'package:shenliyuan/services/poll_service.dart';
import 'package:shenliyuan/widgets/poll/poll_post_card.dart';

class _Service extends PollService {
  _Service() : super(Dio());
}

Post _post({bool multiple = true}) {
  final now = DateTime.utc(2026, 7, 18);
  return Post(id: 1, title: '校园投票', content: '说明', boardId: 1, authorId: 2, postType: 'poll', contentKind: 'poll', createdAt: now, pollMeta: PollMeta(id: 1, postId: 1, category: 'other', selectionMode: multiple ? 'multiple' : 'single', maxChoices: multiple ? 2 : 1, resultsVisibility: 'always', allowChange: true, status: 'active', effectiveStatus: 'active', endsAt: now.add(const Duration(days: 1)), remainingSeconds: 3600, participantCount: 0, hasVoted: false, resultsVisible: true, canVote: true, canChange: false, isOwner: false, options: const [PollOption(id: 10, text: '选项一', sortOrder: 0), PollOption(id: 11, text: '选项二', sortOrder: 1), PollOption(id: 12, text: '选项三', sortOrder: 2)]));
}

void main() {
  testWidgets('多选卡片最多保留最大选择数', (tester) async {
    await tester.pumpWidget(ChangeNotifierProvider(create: (_) => PollProvider(_Service()), child: MaterialApp(home: Scaffold(body: PollPostCard(post: _post())))));
    await tester.tap(find.text('选项一'));
    await tester.tap(find.text('选项二'));
    await tester.tap(find.text('选项三'));
    await tester.pump();
    expect(find.text('最多选择 2 项'), findsOneWidget);
  });
}
