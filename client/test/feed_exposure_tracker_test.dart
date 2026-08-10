import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visibility_detector/visibility_detector.dart';

import 'package:shenliyuan/models/post.dart';
import 'package:shenliyuan/services/feed_event_service.dart';
import 'package:shenliyuan/services/feed_session_service.dart';
import 'package:shenliyuan/widgets/feed/feed_exposure_tracker.dart';

Post _post(int id) => Post(
      id: id,
      content: '内容 $id',
      boardId: 1,
      authorId: 1,
      createdAt: DateTime.utc(2026, 8, 1),
    );

Widget _trackerCard({
  required FeedSessionService session,
  required FeedEventService event,
  required int postId,
}) {
  return FeedExposureTracker(
    post: _post(postId),
    feedKind: 'all',
    position: 0,
    algorithmVersion: 'home_all_v3_poll',
    sessionService: session,
    eventService: event,
    child: Container(height: 100, color: Colors.blue),
  );
}

void main() {
  // visibility_detector 在测试里用帧末回调而非内部 Timer。
  VisibilityDetectorController.instance.updateInterval = Duration.zero;

  Future<(FeedSessionService, FeedEventService)> pumpCard(
    WidgetTester tester,
    int postId,
    double offset,
  ) async {
    final session = FeedSessionService()..newSession();
    final event = FeedEventService(Dio());
    final controller = ScrollController(initialScrollOffset: offset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            controller: controller,
            children: [
              _trackerCard(session: session, event: event, postId: postId),
            ],
          ),
        ),
      ),
    );
    await tester.pump(); // 帧末触发可见性回调
    addTearDown(controller.dispose);
    return (session, event);
  }

  testWidgets('可见不足一半（40%）不曝光', (tester) async {
    // 卡高 100，向下滚 60 → 只剩 40px 可见（40%）。
    final (_, event) = await pumpCard(tester, 1, 60);
    await tester.pump(const Duration(milliseconds: 800));
    expect(event.pendingEvents, isEmpty, reason: '可见 <50% 不应曝光');
    event.dispose();
  });

  testWidgets('可见 ≥50% 且连续 ≥700ms 才曝光，同一 session 不重复计数',
      (tester) async {
    final (_, event) = await pumpCard(tester, 2, 0); // 完全可见
    await tester.pump(const Duration(milliseconds: 500));
    expect(event.pendingEvents, isEmpty, reason: '500ms 未达 700ms 阈值');

    await tester.pump(const Duration(milliseconds: 200));
    expect(event.pendingEvents, hasLength(1));
    expect(event.pendingEvents.single.type, 'impression');
    expect(event.pendingEvents.single.visibleMs, 700);

    // 继续可见：同一 session 内不重复上报。
    await tester.pump(const Duration(seconds: 2));
    expect(event.pendingEvents, hasLength(1));
    event.dispose();
  });

  testWidgets('完全不可见不曝光', (tester) async {
    final (_, event) = await pumpCard(tester, 3, 200); // 卡完全滚出顶部
    await tester.pump(const Duration(milliseconds: 800));
    expect(event.pendingEvents, isEmpty);
    event.dispose();
  });
}
