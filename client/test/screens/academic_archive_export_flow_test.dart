import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/exam_schedule.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/screens/exam_schedule_screen.dart';
import 'package:shenliyuan/services/academic_archive_exporter.dart';
import 'package:shenliyuan/services/exam_schedule_repository.dart';
import '../helpers/load_test_fonts.dart';
import '../helpers/golden_viewport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory temp;
  setUpAll(loadTestFonts);
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('exam_export_ui_');
    messenger.setMockMethodCallHandler(paths, (_) async => temp.path);
    final now = DateTime.now();
    final startYear = now.month >= 8 ? now.year : now.year - 1;
    final semester =
        '$startYear-${startYear + 1}-${now.month >= 8 || now.month <= 2 ? '01' : '02'}';
    AppPreferencesStore.setMockInitialValues({
      ExamScheduleRepository.localExamsKey: jsonEncode([
        ExamModel(
                name: '数据结构',
                startTime: now,
                endTime: now.add(const Duration(hours: 2)),
                location: '教学楼',
                semester: semester)
            .toJson()
      ])
    });
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(paths, null);
    messenger.setMockMethodCallHandler(AcademicArchiveExporter.channel, null);
    await temp.delete(recursive: true);
  });
  testWidgets('考试导出公共文件失败可重试，窄屏成功提示可见', (tester) async {
    await setGoldenViewport(tester, GoldenViewports.phone360x800);
    bool fail = true;
    messenger.setMockMethodCallHandler(AcademicArchiveExporter.channel,
        (call) async {
      final payload = jsonDecode(call.arguments['content'] as String);
      expect(payload['exams'].single['name'], '数据结构');
      expect(call.arguments['folder'], '考试存档');
      if (fail) {
        throw PlatformException(
            code: 'ARCHIVE_EXPORT_FAILED', message: '下载目录写入失败');
      }
      return {'savedPath': 'Download/沈理校园/考试存档/考试.json'};
    });
    final capture = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(
        key: capture,
        child: ChangeNotifierProvider(
            create: (_) => ThemeProvider(loadOnStart: false),
            child: MaterialApp(
                theme: ThemeData(fontFamily: 'NotoSansCJKsc'),
                home: const ExamScheduleScreen()))));
    await tester.pumpAndSettle();
    Future<void> export() async {
      await tester.tap(find.byTooltip('导出存档'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确定导出'));
      await tester.pumpAndSettle();
      // 文件系统异步操作与平台回包分别推进，避免 fakeAsync 阻塞 IO 链。
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    await export();
    expect(find.textContaining('导出失败:'), findsOneWidget);
    expect((await ExamScheduleRepository().load()).length, 1);
    fail = false;
    ScaffoldMessenger.of(tester.element(find.byType(ExamScheduleScreen)))
        .clearSnackBars();
    await tester.pumpAndSettle();
    await export();
    expect(find.textContaining('Download/沈理校园/考试存档/考试.json'), findsOneWidget);
    expect(tester.takeException(), isNull);
    final screenshot = Platform.environment['ARCHIVE_QA_SCREENSHOT'];
    if (screenshot != null) {
      final boundary =
          capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(screenshot).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
  });
  testWidgets('空考试列表不发起公共文件写入', (tester) async {
    AppPreferencesStore.setMockInitialValues({});
    messenger.setMockMethodCallHandler(AcademicArchiveExporter.channel,
        (_) async {
      fail('空列表不应写入');
    });
    await tester.pumpWidget(const MaterialApp(home: ExamScheduleScreen()));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('导出存档'));
    await tester.pump();
    expect(find.text('当前学期没有可导出的考试'), findsOneWidget);
  });
}
