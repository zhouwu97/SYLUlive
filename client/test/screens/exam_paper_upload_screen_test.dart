import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/exam_paper.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/exam_papers/exam_paper_upload_screen.dart';
import 'package:shenliyuan/services/exam_paper_service.dart';

class _FailingUploadService extends ExamPaperService {
  _FailingUploadService() : super(Dio());

  @override
  Future<ExamPaper> upload({
    required PlatformFile file,
    required String courseName,
    required String academicYear,
    required String semester,
    required String examType,
    required bool privacyConfirmed,
    ProgressCallback? onSendProgress,
  }) async {
    throw const ExamPaperApiException(
      message: '上传失败，请稍后重试',
      code: 'network_error',
    );
  }
}

void main() {
  testWidgets('投稿条件完成前按钮禁用，选择有效 PDF 后展示校验状态', (tester) async {
    await tester.pumpWidget(
      _buildApp(
        service: _FailingUploadService(),
        pickFile: () async => PlatformFile(
          name: '高等数学期末试卷.pdf',
          size: 2516582,
          path: 'C:/tmp/高等数学期末试卷.pdf',
        ),
      ),
    );

    expect(find.text('填写信息'), findsOneWidget);
    expect(find.text('选择文件'), findsOneWidget);
    expect(find.text('隐私确认'), findsOneWidget);
    expect(find.text('提交'), findsOneWidget);
    expect(_submitButton(tester).onPressed, isNull);

    await tester.enterText(find.byType(TextFormField).first, '高等数学');
    await _scrollToFileSection(tester);
    await tester.tap(find.widgetWithText(OutlinedButton, '选择'));
    await tester.pumpAndSettle();

    expect(find.text('高等数学期末试卷.pdf'), findsOneWidget);
    expect(find.text('2.4 MB'), findsOneWidget);
    expect(find.text('校验通过'), findsOneWidget);
    expect(_submitButton(tester).onPressed, isNull);

    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    expect(_submitButton(tester).onPressed, isNotNull);
  });

  testWidgets('上传失败后保留课程、文件与隐私确认', (tester) async {
    await tester.pumpWidget(
      _buildApp(
        service: _FailingUploadService(),
        initialCourseName: '数据结构',
        pickFile: () async => PlatformFile(
          name: '数据结构.pdf',
          size: 1024,
          path: 'C:/tmp/数据结构.pdf',
        ),
      ),
    );

    await _scrollToFileSection(tester);
    await tester.tap(find.widgetWithText(OutlinedButton, '选择'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    await tester.tap(find.text('确认投稿'));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -160));
    await tester.pump();

    expect(find.text('上传失败，请稍后重试'), findsOneWidget);
    expect(find.text('数据结构.pdf'), findsOneWidget);
    expect(find.textContaining('数据结构 ·'), findsOneWidget);
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);
  });
}

Widget _buildApp({
  required ExamPaperService service,
  required Future<PlatformFile?> Function() pickFile,
  String initialCourseName = '',
}) {
  return ChangeNotifierProvider<ThemeProvider>(
    create: (_) => ThemeProvider(loadOnStart: false),
    child: MaterialApp(
      home: ExamPaperUploadScreen(
        service: service,
        isAdmin: false,
        pickFile: pickFile,
        initialCourseName: initialCourseName,
      ),
    ),
  );
}

FilledButton _submitButton(WidgetTester tester) {
  return tester.widget<FilledButton>(
    find.widgetWithText(FilledButton, '确认投稿'),
  );
}

Future<void> _scrollToFileSection(WidgetTester tester) async {
  await tester.drag(find.byType(ListView), const Offset(0, -260));
  await tester.pumpAndSettle();
}
