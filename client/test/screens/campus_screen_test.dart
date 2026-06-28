import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/screens/campus_screen.dart';

void main() {
  group('CampusScreen 占位文案清除', () {
    testWidgets('不再出现"内容接入中"或"待接入"', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: CampusScreen()),
      );

      // 等待初始帧和加载状态
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // 搜索整个 widget 树中的文本
      final placeholderTexts = ['内容接入中', '待接入', '学校官方公告内容接入中', '校园资讯内容接入中'];

      for (final text in placeholderTexts) {
        expect(
          find.text(text),
          findsNothing,
          reason: '页面上不应再出现占位文案: "$text"',
        );
      }
    });

    testWidgets('保留"校园"标题和"校园服务"区域', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: CampusScreen()),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('校园'), findsOneWidget);
      expect(find.text('校园服务'), findsOneWidget);
    });

    testWidgets('保留"校园资讯"区域标题', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: CampusScreen()),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('校园资讯'), findsOneWidget);
    });

    testWidgets('加载状态下显示骨架屏而非占位文案', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: CampusScreen()),
      );
      // pump 多帧让 Dio 异步请求的 error 回调执行完毕
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));

      // 不应出现"内容接入中"
      expect(find.text('内容接入中'), findsNothing);
      // 不应出现"待接入"
      expect(find.text('待接入'), findsNothing);
    });
  });
}
