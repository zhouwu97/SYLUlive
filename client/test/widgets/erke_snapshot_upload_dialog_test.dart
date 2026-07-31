import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/personal_data_sync/erke_snapshot_upload.dart';
import 'package:shenliyuan/widgets/erke_snapshot_upload_dialog.dart';

void main() {
  testWidgets('二课摘要授权弹窗完整展示隐私范围和自动上传提醒', (tester) async {
    await _pumpDialog(tester);

    expect(find.text('是否上传二课摘要？'), findsOneWidget);
    expect(find.text('仅上传摘要'), findsOneWidget);
    expect(find.text('敏感信息留在本机'), findsOneWidget);
    expect(find.textContaining('每次更新二课都会同步摘要'), findsOneWidget);
    expect(find.text('仅本次上传'), findsOneWidget);
    expect(find.text('之后自动上传'), findsOneWidget);
    expect(find.text('下次再问'), findsOneWidget);
    expect(find.text('永不上传'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final entry in <ValueKey<String>, ErkeSnapshotUploadPolicy>{
    const ValueKey('erke-upload-once'): ErkeSnapshotUploadPolicy.uploadThisTime,
    const ValueKey('erke-upload-auto'):
        ErkeSnapshotUploadPolicy.autoUploadSummary,
    const ValueKey('erke-upload-later'):
        ErkeSnapshotUploadPolicy.askEveryUpdate,
    const ValueKey('erke-upload-never'): ErkeSnapshotUploadPolicy.neverUpload,
  }.entries) {
    testWidgets('二课摘要授权操作返回 ${entry.value.name}', (tester) async {
      ErkeSnapshotUploadPolicy? result;
      await _pumpDialog(tester, onResult: (value) => result = value);

      await tester.tap(find.byKey(entry.key));
      await tester.pumpAndSettle();

      expect(result, entry.value);
      expect(find.byType(ErkeSnapshotUploadDialog), findsNothing);
    });
  }
}

Future<void> _pumpDialog(
  WidgetTester tester, {
  ValueChanged<ErkeSnapshotUploadPolicy?>? onResult,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: FilledButton(
              onPressed: () async {
                final result = await showErkeSnapshotUploadDialog(context);
                onResult?.call(result);
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
}
