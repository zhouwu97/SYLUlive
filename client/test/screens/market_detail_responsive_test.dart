import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/post.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/post_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/post_detail_screen.dart';

import '../helpers/golden_test_app.dart';
import '../helpers/golden_viewport.dart';
import '../helpers/load_test_fonts.dart';

class _Auth extends ChangeNotifier implements AuthProvider {
  _Auth(this.dio);
  @override
  final Dio dio;
  @override
  User get user => User(
      id: 1, studentId: 'test', nickname: '测试用户', createdAt: DateTime(2026));
  @override
  bool get isLoggedIn => true;
  @override
  int get sessionGeneration => 0;
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

Widget _app({required bool images, bool capturedSplit = false}) {
  final json = <String, dynamic>{
    'id': 100,
    'title': '测试商品',
    'content': '商品说明',
    'board_id': 2,
    'post_type': 'sell',
    'price': 99,
    'author_id': 1,
    'created_at': '2026-10-01T00:00:00Z',
    'images': images
        ? [
            {
              'id': 1,
              'url': 'https://fixture.invalid/image.png',
              'width': 800,
              'height': 600
            }
          ]
        : <Map<String, dynamic>>[],
  };
  final dio = Dio();
  dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
    handler.resolve(Response(
        requestOptions: options,
        statusCode: 200,
        data: options.path == '/posts/100'
            ? json
            : {'replies': [], 'total': 0, 'next_cursor': ''}));
  }));
  return MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>(create: (_) => _Auth(dio)),
        ChangeNotifierProvider(
            create: (_) => PostProvider(dio, enableCache: false)),
        ChangeNotifierProvider(
            create: (_) => ThemeProvider(loadOnStart: false)),
      ],
      child: GoldenTestApp(
          home: PostDetailScreen(
              postId: 100,
              isMarket: true,
              isDesktopSplitMode: capturedSplit,
              initialPost: Post.fromJson(json))));
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() {
    AppPreferencesStore.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => Directory.systemTemp.path);
  });
  tearDown(() => TestDefaultBinaryMessengerBinding
      .instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'), null));

  for (final startsWide in [true, false]) {
    testWidgets('商品详情连续 resize，初始分栏=$startsWide，草稿焦点保留', (tester) async {
      tester.view.devicePixelRatio = 1;
      const wide = GoldenViewports.tabletLandscape1280x800;
      const narrow = GoldenViewports.tabletSplit600x800;
      await setGoldenViewport(tester, startsWide ? wide : narrow);
      await tester.pumpWidget(_app(images: true, capturedSplit: startsWide));
      await tester.pumpAndSettle();
      final input = find.byKey(const ValueKey('post-reply-input'));
      await tester.enterText(input, '保留我的回复草稿');
      await tester.pump();
      tester.view.viewInsets = const FakeViewPadding(bottom: 240);
      addTearDown(tester.view.resetViewInsets);
      final state = tester.state(find.byType(PostDetailScreen));
      for (final size in [narrow, wide, narrow, wide]) {
        await setGoldenViewport(tester, size);
        await tester.pumpAndSettle();
        expect(
            find.byKey(ValueKey(
                size == wide ? 'market-detail-split' : 'market-detail-single')),
            findsOneWidget);
        expect(tester.state(find.byType(PostDetailScreen)), same(state));
        final field = tester.widget<TextField>(input);
        expect(field.controller!.text, '保留我的回复草稿');
        expect(field.focusNode!.hasFocus, isTrue);
        expect(
            tester
                .getRect(
                    find.byKey(const ValueKey('post-reply-input-container')))
                .bottom,
            lessThanOrEqualTo(size.height - 240));
        expect(tester.takeException(), isNull);
      }
    });
  }

  testWidgets('无图片商品在横屏也使用完整正文宽度', (tester) async {
    tester.view.devicePixelRatio = 1;
    await setGoldenViewport(tester, GoldenViewports.tabletLandscape1280x800);
    await tester.pumpWidget(_app(images: false, capturedSplit: true));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('market-detail-single')), findsOneWidget);
    expect(find.text('没有图片展示'), findsNothing);
    expect(
        tester
            .getSize(find.byKey(const ValueKey('post-reply-input-container')))
            .width,
        greaterThan(700));
    expect(tester.takeException(), isNull);
  });
}
