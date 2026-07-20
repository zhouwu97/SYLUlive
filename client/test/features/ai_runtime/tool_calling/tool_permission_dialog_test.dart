import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/ai_runtime/skills/personal_skill.dart';
import 'package:shenliyuan/features/ai_runtime/tool_calling/tool_call_models.dart';
import 'package:shenliyuan/features/ai_runtime/tool_calling/tool_permission_dialog.dart';
import 'package:shenliyuan/features/campus_data/storage/personal_snapshot_models.dart';

void main() {
  testWidgets('低敏感预览展示字段、时间和载荷指纹', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ToolPermissionDialog(preview: _preview(SkillSensitivity.low)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('个人数据授权'), findsOneWidget);
    expect(find.text('本次会话允许'), findsOneWidget);
    await tester.tap(find.text('查看详细字段'));
    await tester.pumpAndSettle();
    expect(find.text('载荷指纹 abcdef012345 · 42 字符'), findsOneWidget);
    expect(find.text('课程、时间'), findsOneWidget);
  });

  testWidgets('中敏感预览不提供会话长期授权', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body:
              ToolPermissionDialog(preview: _preview(SkillSensitivity.medium)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('本次会话允许'), findsNothing);
    expect(find.text('允许本次'), findsOneWidget);
  });
}

ToolPermissionPreview _preview(SkillSensitivity sensitivity) =>
    ToolPermissionPreview(
      toolId: 'personal.schedule.today',
      sensitivity: sensitivity,
      destination: '测试模型',
      dataItems: <ToolDataPreviewItem>[
        ToolDataPreviewItem(
          dataType: PersonalDataType.schedule,
          label: '今日课表',
          fetchedAt: DateTime(2026, 7, 20, 8),
        ),
      ],
      excludedDataLabels: const <String>['完整成绩'],
      outputFields: const <String>['课程、时间'],
      payloadHash: 'abcdef0123456789',
      payloadSize: 42,
    );
