import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/exam_paper.dart';
import 'package:shenliyuan/screens/exam_papers/exam_paper_preview_screen.dart';
import 'package:shenliyuan/services/exam_paper_service.dart';

class _RetryPreviewService extends ExamPaperService {
  _RetryPreviewService() : super(Dio());

  final Completer<File> retryCompleter = Completer<File>();
  int calls = 0;

  @override
  Future<File> downloadPreview(ExamPaper paper) {
    calls += 1;
    if (calls == 1) {
      throw const ExamPaperApiException(
        message: '首次加载失败',
        code: 'preview_failed',
      );
    }
    return retryCompleter.future;
  }
}

void main() {
  testWidgets('预览失败后重新加载会清除旧错误并显示加载状态', (tester) async {
    final service = _RetryPreviewService();
    await tester.pumpWidget(
      MaterialApp(
        home: ExamPaperPreviewScreen(
          paper: _paper(),
          service: service,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('首次加载失败'), findsOneWidget);
    await tester.tap(find.text('重新加载'));
    await tester.pump();

    expect(service.calls, 2);
    expect(find.text('首次加载失败'), findsNothing);
    expect(find.text('正在准备安全预览…'), findsOneWidget);
  });
}

ExamPaper _paper() {
  return ExamPaper.fromJson({
    'id': 1,
    'status': 'published',
    'source': 'user',
    'course_name': '高等数学',
    'academic_year': '2025-2026',
    'semester': 'first',
    'exam_type': 'final',
    'title': '高等数学 · 2025-2026 · 第一学期 · 期末',
    'file_size': 1024,
    'download_count': 0,
    'created_at': '2026-07-10T10:00:00Z',
    'contributor': {
      'id': 1,
      'avatar': '',
      'nickname': '测试用户',
      'level': 1,
    },
  });
}
