import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/legal/legal_documents.dart';
import 'package:shenliyuan/app_bootstrap.dart';
import 'package:shenliyuan/models/campus_article.dart';
import 'package:shenliyuan/models/browsing_history_item.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/repositories/browsing_history_repository.dart';
import 'package:shenliyuan/screens/legal_documents_screen.dart';
import 'package:shenliyuan/screens/campus_article_detail_screen.dart';
import 'package:shenliyuan/widgets/app_card.dart';
import 'package:shenliyuan/theme/app_radius.dart';
import 'package:shenliyuan/theme/app_spacing.dart';

import '../helpers/content_surface_fixtures.dart';
import '../helpers/golden_test_app.dart';
import '../helpers/golden_viewport.dart';
import '../helpers/load_test_fonts.dart';

// 对照页面约定的内容 inset；仅比较开关前后会漏掉两边同时被挤窄。
void main() {
  setUpAll(loadTestFonts);
  setUp(() => AppPreferencesStore.setMockInitialValues({}));

  for (final profile in [
    'primary',
    'wide-phone',
    'dark',
    'large-text',
    'tablet'
  ]) {
    for (final scene in [
      'flags',
      'permissions',
      'likes',
      'social',
      'history',
      'legal',
      'document',
      'article',
      'poll',
    ]) {
      testWidgets('$scene $profile 沿用原页面内容宽度和留白', (tester) async {
        await setGoldenViewport(
            tester,
            switch (profile) {
              'wide-phone' => GoldenViewports.phone390x844,
              'tablet' => GoldenViewports.tabletPortrait768x1024,
              _ => GoldenViewports.phone360x800,
            });
        final appearance = ThemeProvider(loadOnStart: false);
        addTearDown(appearance.dispose);
        await appearance.setBackgroundImage('morenbeijing.jpeg');
        await BrowsingHistoryRepository().recordVisit(
          userId: '1',
          targetId: '300',
          type: BrowsingHistoryType.post,
          title: '校园里的新鲜事',
          author: '测试同学',
        );
        final document = LegalDocuments.all.first;
        if (scene == 'article') {
          final interceptor = InterceptorsWrapper(onRequest: (o, h) {
            h.resolve(Response(requestOptions: o, statusCode: 200, data: {
              'item': {
                'id': 1,
                'title': '校园文章原布局',
                'content_text': '核对原来的正文宽度和留白。',
              }
            }));
          });
          getSharedDio().interceptors.insert(0, interceptor);
          addTearDown(() => getSharedDio().interceptors.remove(interceptor));
        }
        final home = switch (scene) {
          'legal' => const LegalDocumentsScreen(),
          'document' => LegalDocumentsScreen(initialDocumentId: document.id),
          'article' => const CampusArticleDetailScreen(
              summary: CampusArticleSummary(id: 1)),
          _ => surfaceFixtureScene(scene, surfaceFixtureDio()),
        };
        await tester.pumpWidget(ChangeNotifierProvider.value(
          value: appearance,
          child: GoldenTestApp(
            themeMode: profile == 'dark' ? ThemeMode.dark : ThemeMode.light,
            textScaler: profile == 'large-text'
                ? GoldenTextProfile.large.scaler
                : TextScaler.noScaling,
            home: home,
          ),
        ));
        await tester.pumpAndSettle();
        final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
        final body = tester.getRect(find.byWidget(scaffold.body!));
        final permissionFuture = scene == 'permissions'
            ? tester.element(find.byWidgetPredicate((w) => w is FutureBuilder))
            : null;
        Rect? original;
        for (final glass in [false, true, false]) {
          await appearance.setFrostedGlass(glass);
          await tester.pump();
          if (permissionFuture != null) {
            expect(
                tester
                    .element(find.byWidgetPredicate((w) => w is FutureBuilder)),
                same(permissionFuture));
            expect(find.byType(CircularProgressIndicator), findsNothing,
                reason: '仅切换材质不能重新进入异步加载状态');
          }
          await tester.pumpAndSettle();
          final target = switch (scene) {
            'flags' => find.byType(SwitchListTile).first,
            'permissions' => find.byType(ListView).first,
            'likes' => find.byType(ListTile).first,
            'social' => find.byType(TabBarView),
            'history' => find.byType(Dismissible).first,
            'legal' => find.byType(ListTile).first,
            'document' => find.descendant(
                of: find.byType(ListView), matching: find.text(document.title)),
            'article' => find.text('校园文章原布局'),
            _ => find.text('非官方用户投票，结果仅代表参与用户的选择。'),
          };
          final rect = tester.getRect(target);
          final inset = switch (scene) {
            'likes' => 16.0,
            'document' => 20.0 + AppSpacing.lg,
            'article' => AppSpacing.lg * 2,
            'poll' => 16.0, // 与帖子详情正文、评论保持统一。
            _ => 0.0,
          };
          expect(rect.left - body.left, inset,
              reason: '毛玻璃包裹不能叠加外边距、卡片内边距或装饰边框占位');
          if (scene != 'document' && scene != 'article') {
            expect(rect.width, body.width - inset * 2);
          }
          if (scene == 'flags' || scene == 'permissions' || scene == 'social') {
            expect(rect.top, body.top);
          } else if (scene == 'likes') {
            expect(rect.top - body.top, 16);
          }
          if (scene == 'document' || scene == 'article') {
            final surface = find.byKey(ValueKey(scene == 'document'
                ? 'legal-document-reading-surface'
                : 'campus-article-reading-surface'));
            final material = tester.widget<AppCardSurface>(surface);
            final card = tester.getRect(surface);
            final content = tester.getRect(find.byWidget(material.child!));
            expect((material.decoration! as BoxDecoration).borderRadius,
                BorderRadius.circular(AppRadius.lg));
            expect(card.left - body.left, scene == 'document' ? 20 : 16);
            expect(content.left - card.left, AppSpacing.lg);
            expect(card.right - content.right, AppSpacing.lg);
            expect(content.top - card.top, AppSpacing.lg);
            expect(card.bottom - content.bottom, AppSpacing.lg);
            if (scene == 'document') {
              expect(rect.top - body.top, AppSpacing.lg * 2);
            }
          }
          if (scene == 'legal') {
            final surface = tester.widget<AppCardSurface>(find
                .ancestor(of: target, matching: find.byType(AppCardSurface))
                .first);
            expect((surface.decoration! as BoxDecoration).borderRadius,
                BorderRadius.circular(AppRadius.lg));
          }
          if (scene == 'poll') {
            expect(tester.getRect(find.text('评论 1')).left - body.left, 16);
          }
          original ??= rect;
          expect(rect, original);
          expect(tester.takeException(), isNull);
        }
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}
