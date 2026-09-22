import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/post.dart';
import 'package:shenliyuan/providers/poll_provider.dart';
import 'package:shenliyuan/services/poll_service.dart';
import 'package:shenliyuan/services/publish_session_scope.dart';
import 'package:shenliyuan/screens/poll/poll_composer_screen.dart';

class _Service extends PollService {
  _Service() : super(Dio());
}

/// 记录每次 createPoll 的请求体与幂等键，并让提交失败，方便观察重试身份。
class _RecordingService extends PollService {
  _RecordingService() : super(Dio());

  final List<PollDraft> drafts = <PollDraft>[];
  final List<String?> keys = <String?>[];

  @override
  Future<Post> createPoll(PollDraft draft,
      {String? idempotencyKey, PublishSessionScope? session}) async {
    drafts.add(draft);
    keys.add(idempotencyKey);
    throw const PollApiException('poll_unavailable', '服务暂不可用');
  }

  @override
  Future<List<int>> uploadImages(List<XFile> images,
          {PublishSessionScope? session}) async =>
      [for (var i = 0; i < images.length; i++) 100 + i];
}

void main() {
  testWidgets('编辑器默认保留两个选项并显示必要字段', (tester) async {
    await tester.pumpWidget(ChangeNotifierProvider(
        create: (_) => PollProvider(_Service())..syncSessionUser(10, 1),
        child: const MaterialApp(home: PollComposerScreen())));
    expect(find.text('投票标题'), findsOneWidget);
    expect(find.text('投票选项'), findsOneWidget);
    expect(find.byType(TextField), findsWidgets);
    await tester.scrollUntilVisible(
      find.text('投票设置'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('投票设置'), findsOneWidget);
    expect(find.byIcon(Icons.add), findsWidgets);
    await tester.scrollUntilVisible(
      find.text('实时公开结果'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('实时公开结果'), findsOneWidget);
    expect(find.text('结束后公开结果'), findsOneWidget);
    expect(find.text('仅作者查看'), findsOneWidget);
  });

  group('投票提交的重试身份（默认时长）', () {
    Future<void> open(WidgetTester tester, _RecordingService service) async {
      await tester.pumpWidget(ChangeNotifierProvider(
          create: (_) => PollProvider(service)..syncSessionUser(10, 1),
          child: const MaterialApp(home: PollComposerScreen())));
      await tester.pumpAndSettle();
    }

    Future<void> fill(WidgetTester tester,
        {String title = '去哪吃饭', String a = '食堂', String b = '外卖'}) async {
      await tester.enterText(find.byType(TextField).at(0), title);
      await tester.enterText(find.byType(TextField).at(2), a);
      await tester.enterText(find.byType(TextField).at(3), b);
    }

    Future<void> submit(WidgetTester tester) async {
      await tester.ensureVisible(find.text('发布投票'));
      await tester.tap(find.text('发布投票'));
      await tester.pumpAndSettle();
    }

    /// 让真实时钟前进：[DateTime.now] 在测试里仍是墙钟，
    /// 不拉开距离的话，"动态 getter 重算截止时间"这个缺陷就测不出来。
    Future<void> advanceWallClock(WidgetTester tester) async {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)));
    }

    testWidgets('原样重试复用同一截止时间和同一幂等键', (tester) async {
      final service = _RecordingService();
      await open(tester, service);
      await fill(tester);

      await submit(tester);
      await advanceWallClock(tester);
      await submit(tester);

      expect(service.drafts, hasLength(2));
      expect(service.drafts[1].endsAt, service.drafts[0].endsAt,
          reason: '默认时长是"从提交时刻起 N 小时"，重试之间重算就换了截止时间，'
              '服务端认不出是同一次提交，成功响应丢失时会重复创建投票');
      expect(service.keys[1], service.keys[0], reason: '同一份请求体必须共用同一把幂等键');
    });

    testWidgets('用户改了内容算新的一次提交，截止时间重新计算', (tester) async {
      final service = _RecordingService();
      await open(tester, service);
      await fill(tester);

      await submit(tester);
      await advanceWallClock(tester);
      await fill(tester, title: '改过的标题');
      await submit(tester);

      expect(service.drafts, hasLength(2));
      expect(service.drafts[1].endsAt.isAfter(service.drafts[0].endsAt), isTrue,
          reason: '内容变了就是新的一次提交，截止时间应从新的提交时刻起算');
      expect(service.keys[1], isNot(service.keys[0]),
          reason: '新内容不能沿用旧幂等键，否则服务端会回 idempotency_key_reused');
    });
  });
}
