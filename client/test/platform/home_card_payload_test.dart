import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/platform/home_card/home_card_payload.dart';
import 'package:shenliyuan/platform/home_card/home_card_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('互动卡片业务数据投影', () {
    test('没有添加考试时生成明确空状态', () {
      final payload = HomeCardPayloadFactory.exam(
        const [],
        now: DateTime(2026, 7, 17, 14),
      );

      expect(payload.items, isEmpty);
      expect(payload.subtitle, '暂无待考安排');
      expect(payload.toJson()['empty'], isTrue);
    });

    test('考试卡片只包含尚未结束的安排并按时间排序', () {
      final payload = HomeCardPayloadFactory.exam(
        [
          HomeCardExamData(
            name: '已结束考试',
            startTime: DateTime(2026, 7, 16, 8),
            endTime: DateTime(2026, 7, 16, 10),
            location: 'A101',
          ),
          HomeCardExamData(
            name: '第二场',
            startTime: DateTime(2026, 7, 19, 10),
            endTime: DateTime(2026, 7, 19, 12),
            location: '',
          ),
          HomeCardExamData(
            name: '第一场',
            startTime: DateTime(2026, 7, 18, 8),
            endTime: DateTime(2026, 7, 18, 10),
            location: 'B201',
          ),
        ],
        now: DateTime(2026, 7, 17, 14),
      );

      expect(payload.items.map((item) => item.title), ['第一场', '第二场']);
      expect(payload.items.first.badge, '明天');
      expect(payload.items.last.secondary, '地点待定');
    });

    test('竞赛卡片忽略已结束和已归档项目', () {
      final payload = HomeCardPayloadFactory.competition(
        [
          {
            'title': '保留项目',
            'plan_status': 'preparing',
            'registration_end': '2026-08-01',
          },
          {'title': '已结束项目', 'plan_status': 'finished'},
          {'title': '已归档项目', 'plan_status': 'archived'},
        ],
        now: DateTime(2026, 7, 17),
      );

      expect(payload.items, hasLength(1));
      expect(payload.items.single.title, '保留项目');
      expect(payload.items.single.badge, '准备中');
    });
  });

  test('OHOS 服务使用计划约定的方法名与 JSON 参数', () async {
    const channel = MethodChannel('com.sylulive.harmony/home_card');
    final calls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final service = OhosHomeCardService(channel: channel);
    await service.syncCourseCard({'schemaVersion': 1, 'items': <Object>[]});
    await service.syncExamCard({'schemaVersion': 1, 'items': <Object>[]});
    await service.syncCompetitionCard({
      'schemaVersion': 1,
      'items': <Object>[],
    });
    await service.refreshCards();
    await service.openCardSettings();
    await service.clearAllCards();

    expect(
      calls.map((call) => call.method),
      [
        'syncCourseCard',
        'syncExamCard',
        'syncCompetitionCard',
        'refreshCards',
        'openCardSettings',
        'clearAllCards',
      ],
    );
    final courseArgs = calls.first.arguments as Map<Object?, Object?>;
    expect(jsonDecode(courseArgs['dataJson']! as String), {
      'schemaVersion': 1,
      'items': <Object>[],
    });
  });

  test('三张鸿蒙动态卡片使用官方 router 动作拉起应用', () {
    const pages = [
      'NextCourseCard.ets',
      'TodayCoursesCard.ets',
      'AcademicRemindersCard.ets',
    ];
    for (final page in pages) {
      final source = File(
        'ohos/entry/src/main/ets/widget/pages/$page',
      ).readAsStringSync();
      expect(source, isNot(contains('FormLink(')));
      expect(source, contains('postCardAction(this'));
      expect(source, contains("action: 'router'"));
      expect(source, contains("abilityName: 'EntryAbility'"));
      expect(source, contains('params: { homeCardRoute: this.route }'));
      expect(source, contains('.onClick(() => this.openTargetPage())'));
    }
  });
}
