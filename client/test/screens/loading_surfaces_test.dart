import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/features/academic/presentation/academic_restore_status.dart';
import 'package:shenliyuan/models/exam_paper.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/exam_papers/exam_paper_detail_screen.dart';
import 'package:shenliyuan/services/exam_paper_service.dart';
import 'package:shenliyuan/widgets/app_card.dart';
import 'package:shenliyuan/widgets/global_background_wrapper.dart';
import 'package:shenliyuan/widgets/erke_query_progress.dart';
import 'package:shenliyuan/widgets/course/course_fetch_progress_dialog.dart';

import '../helpers/active_backdrop_filters.dart';
import '../helpers/content_surface_fixtures.dart';
import '../helpers/golden_test_app.dart';
import '../helpers/golden_viewport.dart';
import '../helpers/load_test_fonts.dart';

const _output = String.fromEnvironment('LOADING_SURFACE_QA_OUTPUT');
const _label =
    String.fromEnvironment('LOADING_SURFACE_QA_LABEL', defaultValue: 'after');
const _canvas = ValueKey('loading-qa-canvas');

class _PaperService extends ExamPaperService {
  _PaperService() : super(Dio());
  final download = Completer<File>();
  final preview = Completer<File>();
  int downloads = 0;
  int previews = 0;

  @override
  Future<File> downloadForShare(ExamPaper paper) {
    downloads++;
    return download.future;
  }

  @override
  Future<File> downloadPreview(ExamPaper paper) {
    previews++;
    return preview.future;
  }
}

ExamPaper _paper() => ExamPaper.fromJson({
      'id': 1,
      'status': 'published',
      'source': 'user',
      'course_name': '高等数学',
      'academic_year': '2025-2026',
      'semester': 'first',
      'exam_type': 'final',
      'title': '高等数学 · 第一学期 · 期末',
      'file_size': 1024,
      'download_count': 0,
      'created_at': '2026-11-03T00:00:00Z',
      'contributor': {'id': 1, 'nickname': '测试贡献者', 'avatar': '', 'level': 1},
    });

void _expectReadableButton(WidgetTester tester, String label) {
  final text = find.text(label);
  final button = find.ancestor(
      of: text,
      matching: find.byWidgetPredicate((w) => w is ButtonStyleButton));
  final material = tester.widget<Material>(
      find.descendant(of: button, matching: find.byType(Material)).first);
  final background = material.color!;
  final foreground = DefaultTextStyle.of(tester.element(text)).style.color!;
  expect(background.a, 1, reason: '独立按钮需要稳定底色，壁纸线条不能穿过操作文字');
  expect(foreground.a, 1);
  final a = foreground.computeLuminance(), b = background.computeLuminance();
  final ratio = ((a > b ? a : b) + .05) / ((a < b ? a : b) + .05);
  expect(ratio, greaterThanOrEqualTo(4.5));
  final rect = tester.getRect(button);
  expect(rect.height, greaterThanOrEqualTo(44));
  final labelRect = tester.getRect(text);
  expect(rect.contains(labelRect.topLeft), isTrue);
  expect(rect.contains(labelRect.bottomRight), isTrue);
}

Future<void> _capture(WidgetTester tester, String name) async {
  if (_output.isEmpty) return;
  final boundary =
      tester.renderObject<RenderRepaintBoundary>(find.byKey(_canvas));
  final context = tester.element(find.byKey(_canvas));
  for (final widget in tester.widgetList<Image>(find.byType(Image)).toList()) {
    await tester.runAsync(() => precacheImage(widget.image, context));
  }
  await tester.pump(const Duration(milliseconds: 16));
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    await Directory(_output).create(recursive: true);
    await File('$_output/$_label-$name.png')
        .writeAsBytes(bytes!.buffer.asUint8List());
  });
}

Future<ThemeProvider> _appearance() async {
  final appearance = ThemeProvider(loadOnStart: false);
  addTearDown(appearance.dispose);
  await appearance.setBackgroundImage('morenbeijing.jpeg');
  await appearance.setComponentOpacity(.65);
  await appearance.setFrostedGlass(true);
  return appearance;
}

Widget _app(ThemeProvider appearance, Widget home,
        (String, ThemeMode, double) profile) =>
    ChangeNotifierProvider.value(
        value: appearance,
        child: RepaintBoundary(
          key: _canvas,
          child: GoldenTestApp(
              themeMode: profile.$2,
              textScaler: TextScaler.linear(profile.$3),
              home: home),
        ));

void main() {
  setUpAll(() async {
    await loadTestFonts();
    await (FontLoader('MaterialIcons')
          ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
        .load();
  });
  setUp(() => AppPreferencesStore.setMockInitialValues({}));

  testWidgets('投票已删除状态保留底面且不提供无效重试', (tester) async {
    await setGoldenViewport(tester, GoldenViewports.phone360x800);
    final appearance = await _appearance();
    final dio = surfaceFixtureDio();
    dio.interceptors.insert(0,
        InterceptorsWrapper(onRequest: (options, handler) {
      if (options.path == '/polls/101') {
        handler.reject(DioException(
            requestOptions: options,
            response: Response(
                requestOptions: options,
                statusCode: 404,
                data: {'error': '投票不存在或已删除'})));
      } else {
        handler.next(options);
      }
    }));
    await tester.pumpWidget(_app(appearance, surfaceFixtureScene('poll', dio),
        ('primary', ThemeMode.light, 1.0)));
    await tester.pumpAndSettle();
    final surface = find.byKey(const ValueKey('post-status-surface'));
    expect(tester.getRect(surface).width, 328);
    expect(tester.getRect(surface).height, greaterThan(600));
    expect(find.text('投票不存在或已删除'), findsOneWidget);
    expect(find.text('重试'), findsNothing);
    expect(find.byKey(const ValueKey('poll-comments-surface')), findsNothing);
    await _capture(tester, 'poll-deleted-primary');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final profile in [
    ('primary', ThemeMode.light, 1.0),
    ('wide-phone', ThemeMode.light, 1.0),
    ('dark', ThemeMode.dark, 1.0),
    ('large', ThemeMode.light, 1.3),
    ('stress', ThemeMode.dark, 1.5),
  ]) {
    final viewport = profile.$1 == 'wide-phone'
        ? GoldenViewports.phone390x844
        : GoldenViewports.phone360x800;

    testWidgets('试卷详情次级按钮对比度和下载恢复 ${profile.$1}', (tester) async {
      await setGoldenViewport(tester, viewport);
      final appearance = await _appearance();
      final service = _PaperService();
      await tester.pumpWidget(_app(appearance,
          ExamPaperDetailScreen(paper: _paper(), service: service), profile));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('应用内预览'));
      await tester.pumpAndSettle();
      await _capture(tester, 'paper-actions-${profile.$1}');
      final original = tester.getRect(find.text('应用内预览'));
      for (final glass in [true, false]) {
        await appearance.setFrostedGlass(glass);
        await appearance.setComponentOpacity(.1);
        await tester.pumpAndSettle();
        _expectReadableButton(tester, '应用内预览');
        expect(tester.getRect(find.text('应用内预览')), original);
      }
      await appearance.setFrostedGlass(true);
      await appearance.setComponentOpacity(.65);
      await tester.pumpAndSettle();
      await tester.tap(find.text('下载 / 分享'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      _expectReadableButton(tester, '下载中…');
      expect(service.downloads, 1);
      await tester.tap(find.text('下载中…'));
      expect(service.downloads, 1);
      service.download.completeError(const ExamPaperApiException(
          message: '测试下载失败', code: 'download_failed'));
      await tester.pumpAndSettle();
      expect(find.text('测试下载失败'), findsOneWidget);
      expect(find.text('下载 / 分享'), findsOneWidget);
      await tester.tap(find.text('应用内预览'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(service.previews, 1);
      expect(find.text('正在准备安全预览…'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('应用内预览'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    for (final scene in ['erke', 'course-fetch']) {
      testWidgets('$scene 加载卡片响应材质与不透明度 ${profile.$1}', (tester) async {
        await setGoldenViewport(tester, viewport);
        final appearance = await _appearance();
        await tester.pumpWidget(_app(
            appearance,
            GlobalBackgroundWrapper(
              child: Scaffold(
                backgroundColor: Colors.transparent,
                appBar: AppBar(title: Text(scene == 'erke' ? '二课成绩查询' : '课程表')),
                body: scene == 'erke'
                    ? SingleChildScrollView(
                        padding: const EdgeInsets.all(16),
                        child: ErkeQueryProgress(
                          message: '正在穿透学校内网，请稍候…',
                          decoration: BoxDecoration(
                              color: profile.$2 == ThemeMode.dark
                                  ? const Color(0xFF1E2226)
                                  : Colors.white,
                              borderRadius: BorderRadius.circular(20)),
                        ))
                    : Builder(
                        builder: (context) => Center(
                            child: TextButton(
                                onPressed: () => showDialog<void>(
                                    context: context,
                                    barrierDismissible: false,
                                    builder: (_) => const PopScope(
                                        canPop: false,
                                        child: CourseFetchProgressDialog())),
                                child: const Text('刷新课表')))),
              ),
            ),
            profile));
        if (scene == 'course-fetch') {
          await tester.tap(find.text('刷新课表'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
        } else {
          await tester.pump();
        }
        final surface = find.byKey(ValueKey(scene == 'erke'
            ? 'erke-query-progress-surface'
            : 'course-fetch-progress-surface'));
        final original = tester.getRect(surface);
        if (scene == 'erke') {
          expect(original.width, viewport.width - 32);
        } else {
          // 弹窗按内容定宽，保留左右 48 留白及 Material 的最小可读宽度。
          final availableWidth = viewport.width - 96;
          final minimumWidth = availableWidth < 280 ? availableWidth : 280.0;
          expect(
              original.width, inInclusiveRange(minimumWidth, availableWidth));
          expect(original.center.dx, viewport.width / 2);
        }
        expect(find.descendant(of: surface, matching: activeBackdropFilters()),
            findsOneWidget);
        await _capture(tester, '$scene-loading-${profile.$1}');
        for (final glass in [false, true]) {
          await appearance.setFrostedGlass(glass);
          await tester.pump();
          expect(tester.getRect(surface), original);
          expect(
              find.descendant(of: surface, matching: activeBackdropFilters()),
              glass ? findsOneWidget : findsNothing);
        }
        await appearance.setFrostedGlassStrength(0);
        await tester.pump();
        expect(find.descendant(of: surface, matching: activeBackdropFilters()),
            findsNothing);
        expect(tester.getRect(surface), original);
        await appearance.setCleanBackgroundMode();
        await tester.pump();
        expect(find.descendant(of: surface, matching: activeBackdropFilters()),
            findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }

    testWidgets('课表恢复底面填满可用区域并保留错误重试 ${profile.$1}', (tester) async {
      await setGoldenViewport(tester, viewport);
      final appearance = await _appearance();
      final retry = Completer<void>();
      var requests = 0;
      await tester.pumpWidget(_app(
          appearance,
          GlobalBackgroundWrapper(
            child: Scaffold(
                backgroundColor: Colors.transparent,
                appBar: AppBar(title: const Text('课程表')),
                body: Center(child: AcademicRestoreStatus(onRetry: () {
                  requests++;
                  return retry.future;
                }))),
          ),
          profile));
      addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
      await tester.pump();
      final surface = find.descendant(
          of: find.byType(AcademicRestoreStatus),
          matching: find.byType(AppCardSurface));
      final expected = Rect.fromLTRB(
          16,
          tester.getRect(find.byType(AppBar)).bottom + 16,
          viewport.width - 16,
          viewport.height - 16);
      await _capture(tester, 'schedule-loading-${profile.$1}');
      expect(tester.getRect(surface), expected);
      expect(find.descendant(of: surface, matching: activeBackdropFilters()),
          findsOneWidget);
      final state = tester.state(find.byType(AcademicRestoreStatus));
      await appearance.setFrostedGlass(false);
      await tester.pump();
      expect(tester.getRect(surface), expected);
      expect(tester.state(find.byType(AcademicRestoreStatus)), same(state));
      expect(find.descendant(of: surface, matching: activeBackdropFilters()),
          findsNothing);
      await tester.pump(const Duration(seconds: 15));
      expect(find.text('课表恢复暂未完成'), findsOneWidget);
      expect(tester.getRect(surface), expected);
      await tester.tap(find.text('重试恢复'));
      await tester.pump();
      expect(requests, 1);
      expect(find.text('正在恢复本机课表状态'), findsOneWidget);
      retry.complete();
      await tester.pump();
      await appearance.setFrostedGlass(true);
      await tester.pump();
      await appearance.setCleanBackgroundMode();
      await tester.pump();
      expect(tester.getRect(surface), expected);
      expect(find.descendant(of: surface, matching: activeBackdropFilters()),
          findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    for (final scene in ['post', 'poll']) {
      testWidgets('$scene 加载和失败使用同一块底面且可重试 ${profile.$1}', (tester) async {
        await setGoldenViewport(tester, viewport);
        final appearance = await _appearance();
        final dio = surfaceFixtureDio();
        final gate = Completer<void>();
        var fail = true;
        var requests = 0;
        dio.interceptors.insert(0,
            InterceptorsWrapper(onRequest: (options, handler) async {
          if (options.path == (scene == 'post' ? '/posts/300' : '/polls/101')) {
            requests++;
            if (fail) {
              await gate.future;
              handler.reject(DioException(
                  requestOptions: options,
                  response: Response(
                      requestOptions: options,
                      statusCode: 503,
                      data: {'error': '测试服务暂时不可用'})));
              return;
            }
          }
          handler.next(options);
        }));
        await tester.pumpWidget(
            _app(appearance, surfaceFixtureScene(scene, dio), profile));
        await tester.pump(const Duration(milliseconds: 1));
        final surface = find.byKey(const ValueKey('post-status-surface'));
        await _capture(tester, '$scene-loading-${profile.$1}');
        expect(surface, findsOneWidget);
        final original = tester.getRect(surface);
        expect(original.left, 16);
        expect(original.right, viewport.width - 16);
        expect(original.height, greaterThan(600));
        expect(find.descendant(of: surface, matching: activeBackdropFilters()),
            findsOneWidget);
        await appearance.setFrostedGlass(false);
        await tester.pump();
        expect(tester.getRect(surface), original);
        expect(requests, 1);
        gate.complete();
        await tester.pumpAndSettle();
        expect(find.text('重试'), findsOneWidget);
        expect(tester.getRect(surface), original);
        await appearance.setFrostedGlass(true);
        await tester.pumpAndSettle();
        await _capture(tester, '$scene-error-${profile.$1}');
        fail = false;
        await tester.tap(find.text('重试'));
        await tester.pumpAndSettle();
        expect(requests, 2);
        expect(surface, findsNothing);
        expect(
            scene == 'post'
                ? find.text('还没有评论，来说点什么吧')
                : find.byKey(const ValueKey('poll-comments-surface')),
            findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}
