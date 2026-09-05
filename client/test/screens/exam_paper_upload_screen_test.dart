import 'dart:convert';
import 'dart:typed_data';

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
      message: '文件服务器空间不足，请稍后重试',
      code: 'insufficient_storage',
    );
  }
}

class _SuccessfulUploadService extends ExamPaperService {
  _SuccessfulUploadService() : super(Dio());

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
    onSendProgress?.call(file.size, file.size);
    return ExamPaper.fromJson({
      'id': 21,
      'status': 'pending',
      'source': 'user',
      'course_name': courseName,
      'academic_year': academicYear,
      'semester': semester,
      'exam_type': examType,
      'title': '$courseName · $academicYear',
      'file_size': file.size,
      'download_count': 0,
      'created_at': '2026-07-13T10:00:00Z',
      'contributor': {
        'id': 1,
        'avatar': '',
        'nickname': '测试用户',
        'level': 1,
      },
    });
  }
}

class _JsonAdapter implements HttpClientAdapter {
  final List<(int, Object)> responses;

  _JsonAdapter(this.responses);

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    await requestStream?.drain<void>();
    final response = responses.removeAt(0);
    return ResponseBody.fromString(
      jsonEncode(response.$2),
      response.$1,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
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
    final apiDio = Dio(BaseOptions(baseUrl: 'https://couqie.ccwu.cc/api'))
      ..httpClientAdapter = _JsonAdapter([
        (
          201,
          {
            'session_id': 'screen-session',
            'upload_url': 'https://139.196.148.174/v1/uploads/screen-session',
            'upload_token': 'screen-upload-token',
            'expires_at': '2026-07-13T10:10:00Z',
          },
        ),
      ]);
    final storageDio = Dio()
      ..httpClientAdapter = _JsonAdapter([
        (507, {'error': 'insufficient storage'}),
      ]);
    await tester.pumpWidget(
      _buildApp(
        service: ExamPaperService(apiDio, storageDio: storageDio),
        initialCourseName: '数据结构',
        pickFile: () async => PlatformFile(
          name: '数据结构.pdf',
          size: 1024,
          bytes: Uint8List.fromList(List<int>.filled(1024, 1)),
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

    expect(find.text('文件服务器空间不足，请稍后重试'), findsOneWidget);
    expect(find.text('数据结构.pdf'), findsOneWidget);
    expect(find.textContaining('数据结构 ·'), findsOneWidget);
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);
    expect(_submitButton(tester).onPressed, isNotNull);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('上传成功后把待审核试卷返回上一页', (tester) async {
    await tester.pumpWidget(
      _buildRoutedApp(
        service: _SuccessfulUploadService(),
        pickFile: () async => PlatformFile(
          name: '操作系统.pdf',
          size: 1024,
          bytes: Uint8List.fromList(List<int>.filled(1024, 1)),
        ),
      ),
    );

    await tester.tap(find.text('打开投稿'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, '操作系统');
    await _scrollToFileSection(tester);
    await tester.tap(find.widgetWithText(OutlinedButton, '选择'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    await tester.tap(find.text('确认投稿'));
    await tester.pumpAndSettle();

    final expectedAcademicYear =
        ExamPaperMetadata.academicYears(DateTime.now()).first;
    expect(find.text('投稿成功：操作系统 · $expectedAcademicYear'), findsOneWidget);
    expect(find.byType(ExamPaperUploadScreen), findsNothing);
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

Widget _buildRoutedApp({
  required ExamPaperService service,
  required Future<PlatformFile?> Function() pickFile,
}) {
  return ChangeNotifierProvider<ThemeProvider>(
    create: (_) => ThemeProvider(loadOnStart: false),
    child: MaterialApp(
      home: _UploadResultHost(service: service, pickFile: pickFile),
    ),
  );
}

class _UploadResultHost extends StatefulWidget {
  final ExamPaperService service;
  final Future<PlatformFile?> Function() pickFile;

  const _UploadResultHost({required this.service, required this.pickFile});

  @override
  State<_UploadResultHost> createState() => _UploadResultHostState();
}

class _UploadResultHostState extends State<_UploadResultHost> {
  String? resultTitle;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: resultTitle == null
            ? FilledButton(
                onPressed: () async {
                  final paper = await Navigator.of(context).push<ExamPaper>(
                    MaterialPageRoute(
                      builder: (_) => ExamPaperUploadScreen(
                        service: widget.service,
                        isAdmin: false,
                        pickFile: widget.pickFile,
                      ),
                    ),
                  );
                  if (paper != null && mounted) {
                    setState(() => resultTitle = paper.title);
                  }
                },
                child: const Text('打开投稿'),
              )
            : Text('投稿成功：$resultTitle'),
      ),
    );
  }
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
