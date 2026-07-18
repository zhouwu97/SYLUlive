import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/platform/live_view/live_view_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('下一节课实况窗重复同步时更新而不是重复创建', () async {
    const channel = MethodChannel('com.sylulive.harmony/live_view');
    final calls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final service = OhosLiveViewService(channel: channel);
    final start = DateTime(2026, 7, 18, 8);
    final end = DateTime(2026, 7, 18, 9, 40);
    await service.publish(
      type: 'next_class',
      businessId: 'lesson-1001',
      title: '高等数学',
      body: '文体中心203',
      startTime: start,
      endTime: end,
    );
    await service.publish(
      type: 'next_class',
      businessId: 'lesson-1001',
      title: '高等数学',
      body: '文体中心203',
      startTime: start,
      endTime: end,
    );

    expect(calls.map((call) => call.method), [
      'startCourseLiveView',
      'updateCourseLiveView',
    ]);
    final data = jsonDecode(
      (calls.first.arguments as Map<Object?, Object?>)['dataJson']! as String,
    ) as Map<String, dynamic>;
    expect(data['businessId'], 'lesson-1001');
    expect(data['route'], 'campus://timetable');
  });

  test('结束实况窗和未知类型会走明确协议', () async {
    const channel = MethodChannel('com.sylulive.harmony/live_view');
    final calls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final service = OhosLiveViewService(channel: channel);
    await service.publish(
      type: 'course',
      businessId: 'lesson-1002',
      title: '英语',
      body: 'A101',
      startTime: DateTime(2026, 7, 18, 10),
      endTime: DateTime(2026, 7, 18, 12),
    );
    await service.end(type: 'course', businessId: 'lesson-1002');
    expect(calls.last.method, 'endCourseLiveView');
    final endData = jsonDecode(
      (calls.last.arguments as Map<Object?, Object?>)['dataJson']! as String,
    ) as Map<String, dynamic>;
    expect(endData['title'], '');
    expect(endData['body'], '');

    await expectLater(
      service.publish(
        type: 'unknown',
        businessId: 'x',
        title: 'x',
        body: 'x',
        startTime: DateTime(2026),
        endTime: DateTime(2026, 1, 1, 1),
      ),
      throwsArgumentError,
    );
  });

  test('距离上课超过 60 分钟时不创建实况窗', () async {
    const channel = MethodChannel('com.sylulive.harmony/live_view');
    final calls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final service = OhosLiveViewService(channel: channel);
    final now = DateTime(2026, 7, 17, 6, 59);
    await service.syncCourse(
      CourseLiveViewData(
        businessId: 'course-1',
        title: '高等数学',
        location: '文体中心203',
        startTime: DateTime(2026, 7, 17, 8),
        endTime: DateTime(2026, 7, 17, 9, 40),
      ),
      now: now,
    );

    expect(calls, hasLength(1));
    expect(calls.single.method, 'endCourseLiveView');
    expect(calls.map((call) => call.method),
        isNot(contains('startCourseLiveView')));
    await service.dispose();
  });

  test('60 分钟内重复同步会更新同一课程实况窗', () async {
    const channel = MethodChannel('com.sylulive.harmony/live_view');
    final calls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final service = OhosLiveViewService(channel: channel);
    final course = CourseLiveViewData(
      businessId: 'course-2',
      title: '大学英语',
      location: 'A101',
      startTime: DateTime(2026, 7, 17, 8),
      endTime: DateTime(2026, 7, 17, 9, 40),
    );
    final now = DateTime(2026, 7, 17, 7, 30);
    await service.syncCourse(course, now: now);
    await service.syncCourse(course, now: now);

    expect(calls.map((call) => call.method), [
      'startCourseLiveView',
      'updateCourseLiveView',
    ]);
    await service.dispose();
  });

  test('课程到达结束时间后自动结束实况窗', () async {
    const channel = MethodChannel('com.sylulive.harmony/live_view');
    final calls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final service = OhosLiveViewService(channel: channel);
    final now = DateTime.now();
    await service.syncCourse(
      CourseLiveViewData(
        businessId: 'course-3',
        title: '线性代数',
        location: 'B202',
        startTime: now.subtract(const Duration(minutes: 10)),
        endTime: now.add(const Duration(milliseconds: 20)),
      ),
      now: now,
    );
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(calls.map((call) => call.method), [
      'startCourseLiveView',
      'endCourseLiveView',
    ]);
    await service.dispose();
  });
}
