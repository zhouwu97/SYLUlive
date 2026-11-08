import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/theme/app_radius.dart';
import 'package:shenliyuan/widgets/app_card.dart';
import 'package:shenliyuan/widgets/post_reply_composer.dart';
import 'package:shenliyuan/widgets/post_content_link_text.dart';
import 'package:shenliyuan/widgets/post_media/post_media_view.dart';

import '../helpers/content_surface_fixtures.dart';
import '../helpers/golden_test_app.dart';
import '../helpers/golden_viewport.dart';
import '../helpers/load_test_fonts.dart';
import '../helpers/mock_public_image_http.dart';

void main() {
  setUpAll(loadTestFonts);
  setUp(() async {
    AppPreferencesStore.setMockInitialValues({});
    await installMockPublicImageHttp();
  });
  tearDown(uninstallMockPublicImageHttp);

  for (final profile in [
    'light',
    'dark-large',
    'phone-images',
    'wide-images'
  ]) {
    for (final scene in ['post', 'market-detail']) {
      for (final long in [false, true]) {
        testWidgets('$scene $profile long=$long 滚动末尾无重复输入栏留白', (tester) async {
          await setGoldenViewport(
              tester,
              profile == 'wide-images'
                  ? GoldenViewports.tabletLandscape1280x800
                  : GoldenViewports.phone390x844);
          final theme = ThemeProvider(loadOnStart: false);
          addTearDown(theme.dispose);
          await theme.setBackgroundImage('morenbeijing.jpeg');
          final dio = surfaceFixtureDio();
          dio.interceptors.insert(0, InterceptorsWrapper(onRequest: (o, h) {
            if (o.path == '/posts/300') {
              h.resolve(Response(requestOptions: o, statusCode: 200, data: {
                ...surfacePost(),
                if (profile.endsWith('images'))
                  'images': [
                    {
                      'id': 1,
                      'post_id': 300,
                      'file_id': 1,
                      'file': {
                        'id': 1,
                        'path':
                            'https://fixture.invalid/uploads/glass-geometry.png',
                        'width': 800,
                        'height': 600,
                      }
                    }
                  ],
                if (long) 'content': List.filled(35, '长正文用于验证滚动末尾。').join('\n'),
              }));
            } else {
              h.next(o);
            }
          }));
          await tester.pumpWidget(ChangeNotifierProvider.value(
              value: theme,
              child: GoldenTestApp(
                themeMode:
                    profile == 'light' ? ThemeMode.light : ThemeMode.dark,
                textScaler: profile == 'light'
                    ? TextScaler.noScaling
                    : const TextScaler.linear(1.3),
                home: surfaceFixtureScene(scene, dio),
              )));
          await tester.pumpAndSettle();
          Rect? before;
          for (final glass in [false, true, false]) {
            await theme.setFrostedGlass(glass);
            await tester.pumpAndSettle();
            if (scene == 'post') {
              tester
                  .state<ScrollableState>(find.byType(Scrollable).first)
                  .position
                  .jumpTo(0);
              await tester.pumpAndSettle();
              final title = find.byWidgetPredicate(
                  (w) => w is PostContentLinkText && w.text == '校园生活');
              final surface = tester.widget<AppCardSurface>(find
                  .ancestor(of: title, matching: find.byType(AppCardSurface))
                  .first);
              expect((surface.decoration! as BoxDecoration).borderRadius,
                  BorderRadius.circular(AppRadius.lg),
                  reason: '正文使用统一卡片圆角，切换材质不能改变圆角');
            }
            if (profile == 'phone-images' && scene == 'market-detail') {
              final position = tester
                  .state<ScrollableState>(find.byType(Scrollable).first)
                  .position;
              position.jumpTo(0);
              await tester.pumpAndSettle();
              final media = tester.getRect(find.byType(PostMediaView));
              final title = find.byWidgetPredicate(
                  (w) => w is PostContentLinkText && w.text == '校园生活');
              final content = tester.getRect(find
                  .ancestor(of: title, matching: find.byType(AppCardSurface))
                  .first);
              expect(content.top, media.bottom - 24,
                  reason: '材质迁移必须保留商品正文覆盖图片底部的原有 24px 设计');
            }
            final scroll = find.byType(Scrollable).first;
            final position = tester.state<ScrollableState>(scroll).position;
            position.jumpTo(position.maxScrollExtent);
            await tester.pumpAndSettle();
            final empty = find.text('还没有评论，来说点什么吧');
            final surface = find
                .ancestor(of: empty, matching: find.byType(AppCardSurface))
                .first;
            final rect = tester.getRect(surface);
            if (scene == 'post' || scene == 'market-detail') {
              final card = tester.widget<AppCardSurface>(surface);
              expect((card.decoration! as BoxDecoration).borderRadius,
                  BorderRadius.circular(AppRadius.lg));
            }
            final composer = tester.getRect(find.byType(PostReplyComposer));
            // 评论材质延伸到输入栏接缝（底部留白放在材质内），下拉时帖子图片不会从缝里露出。
            expect(composer.top - rect.bottom, 0,
                reason: '评论卡片必须填到输入栏，不能留下露出壁纸或图片的空带');
            if (scene == 'post') {
              final label = find.text('评论 0').first;
              final action = tester.widget<Container>(find
                  .ancestor(of: label, matching: find.byType(Container))
                  .first);
              final border =
                  (action.decoration! as BoxDecoration).border! as Border;
              expect(border.top.color.a, glass ? 0 : greaterThan(0));
              expect(border.bottom.color.a, glass ? 0 : greaterThan(0));
            }
            if (before != null) expect(rect, before);
            before = rect;
            expect(tester.takeException(), isNull);
          }
          await tester.pumpWidget(const SizedBox.shrink());
          if (profile.endsWith('images')) {
            await flushMockPublicImageTimers(tester);
          }
        });
      }
    }
  }

  testWidgets('帖子加载、失败和重试保留背景与圆角错误底面', (tester) async {
    final theme = ThemeProvider(loadOnStart: false);
    addTearDown(theme.dispose);
    await theme.setBackgroundImage('morenbeijing.jpeg');
    final dio = surfaceFixtureDio();
    final pending = Completer<void>();
    var fail = true;
    dio.interceptors.insert(0, InterceptorsWrapper(onRequest: (o, h) async {
      if (o.path == '/posts/300' && fail) {
        await pending.future;
        h.reject(DioException(requestOptions: o, message: '本地失败验收'));
      } else {
        h.next(o);
      }
    }));
    await tester.pumpWidget(ChangeNotifierProvider.value(
        value: theme,
        child: GoldenTestApp(home: surfaceFixtureScene('post', dio))));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    pending.complete();
    await tester.pumpAndSettle();
    expect(find.text('重试'), findsOneWidget);
    expect(
        find.ancestor(
            of: find.text('重试'), matching: find.byType(AppCardSurface)),
        findsOneWidget);
    fail = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('还没有评论，来说点什么吧'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
