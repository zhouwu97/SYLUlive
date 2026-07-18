import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/screens/competition/competition_center_screen.dart';
import 'package:shenliyuan/utils/competition_import_payload.dart';

void main() {
  group('竞赛计划 JSON 导入', () {
    test('解析合法的事件列表', () {
      final payload = decodeCompetitionImportPayload(
        '  {"events":[{"title":"程序设计竞赛"}]}  ',
      );

      expect(payload['events'], isA<List>());
      expect((payload['events'] as List).single['title'], '程序设计竞赛');
    });

    test('拒绝空文本', () {
      expect(
        () => decodeCompetitionImportPayload('  '),
        throwsA(isA<FormatException>()),
      );
    });

    test('拒绝无效 JSON', () {
      expect(
        () => decodeCompetitionImportPayload('{"events":['),
        throwsA(isA<FormatException>()),
      );
    });

    test('拒绝缺少 events 的对象', () {
      expect(
        () => decodeCompetitionImportPayload('{"items":[]}'),
        throwsA(isA<FormatException>()),
      );
    });

    test('拒绝非列表 events', () {
      expect(
        () => decodeCompetitionImportPayload('{"events":{}}'),
        throwsA(isA<FormatException>()),
      );
    });

    test('拒绝超过 2 MB 的内容', () {
      final oversized =
          '{"events":[],"padding":"${'x' * competitionImportMaxBytes}"}';

      expect(
        () => decodeCompetitionImportPayload(oversized),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            'JSON 内容不能超过 2 MB',
          ),
        ),
      );
    });
  });

  testWidgets('OHOS 仅显示 JSON 文本导入且无效内容不会请求服务端', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.fuchsia;
    try {
      await tester.pumpWidget(
        const MaterialApp(home: CompetitionShareImportScreen()),
      );
      await tester.tap(find.text('JSON 文本导入'));
      await tester.pumpAndSettle();

      expect(find.text('选择 JSON 文件'), findsNothing);
      expect(find.text('预览 JSON'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '{"events":[');
      await tester.tap(find.text('预览 JSON'));
      await tester.pump();

      expect(
        find.text('JSON 格式不正确，请检查逗号、引号和括号'),
        findsOneWidget,
      );
      expect(find.text('合并'), findsNothing);
      expect(find.text('覆盖'), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('Android 保留 JSON 文件选择入口', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await tester.pumpWidget(
        const MaterialApp(home: CompetitionShareImportScreen()),
      );
      await tester.tap(find.text('JSON 文件导入'));
      await tester.pumpAndSettle();

      expect(find.text('选择 JSON 文件'), findsOneWidget);
      expect(find.text('预览 JSON'), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
