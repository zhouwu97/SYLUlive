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

  @override
  Future<Post> putBallot(int pollId, List<int> optionIds,
      {String? idempotencyKey}) async =>
      _post(participants: 1);
}

Post _post({bool multiple = true, bool active = true, bool voted = false, bool canChange = true, bool resultsVisible = true, int participants = 0}) {
  final now = DateTime.utc(2026, 7, 18);
  return Post(id: 1, title: '校园投票', content: '说明', boardId: 1, authorId: 2, postType: 'poll', contentKind: 'poll', createdAt: now, pollMeta: PollMeta(id: 1, postId: 1, category: 'other', selectionMode: multiple ? 'multiple' : 'single', maxChoices: multiple ? 2 : 1, resultsVisibility: 'always', allowChange: canChange, status: active ? 'active' : 'closed', effectiveStatus: active ? 'active' : 'closed', endsAt: now.add(const Duration(days: 1)), remainingSeconds: active ? 3600 : 0, participantCount: participants, hasVoted: voted, resultsVisible: resultsVisible, canVote: active && (!voted || canChange), canChange: active && voted && canChange, isOwner: false, options: const [PollOption(id: 10, text: '选项一', sortOrder: 0), PollOption(id: 11, text: '选项二', sortOrder: 1), PollOption(id: 12, text: '选项三', sortOrder: 2)]));
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

  testWidgets('提交成功通过回调立即更新宿主', (tester) async {
    Post? updated;
    await tester.pumpWidget(ChangeNotifierProvider(create: (_) => PollProvider(_Service()), child: MaterialApp(home: Scaffold(body: PollPostCard(post: _post(multiple: false), onPostUpdated: (post) => updated = post)))));
    await tester.tap(find.text('选项一'));
    await tester.pump();
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(updated?.pollMeta?.participantCount, 1);
  });

  testWidgets('结束投票显示结果入口而不是修改按钮', (tester) async {
    await tester.pumpWidget(ChangeNotifierProvider(create: (_) => PollProvider(_Service()), child: MaterialApp(home: Scaffold(body: PollPostCard(post: _post(active: false, voted: true, canChange: false, participants: 1))))));
    expect(find.text('查看投票结果'), findsOneWidget);
    expect(find.text('修改我的选择'), findsNothing);
  });
}
