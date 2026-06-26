import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/campus_article.dart';
import 'package:shenliyuan/screens/campus_article_list_screen.dart';
import 'package:shenliyuan/services/campus_article_service.dart';

/// 可控的 CampusArticleService，用 Completer 控制每个请求何时返回。
class _ControllableArticleService implements CampusArticleService {
  final List<Completer<dynamic>> _pending = [];
  int _articleCallCount = 0;

  @override
  Future<CampusArticleSummary?> getLatestArticle() async {
    final c = Completer<CampusArticleSummary?>();
    _pending.add(c);
    return c.future;
  }

  @override
  Future<CampusArticlePage> getArticles({
    int page = 1,
    int pageSize = 20,
    String? categorySlug,
  }) async {
    _articleCallCount++;
    final c = Completer<CampusArticlePage>();
    _pending.add(c);
    return c.future;
  }

  @override
  Future<CampusArticleDetail> getArticleDetail(int id) async {
    final c = Completer<CampusArticleDetail>();
    _pending.add(c);
    return c.future;
  }

  void completeNext(Object result) {
    if (_pending.isNotEmpty) {
      _pending.removeAt(0).complete(result);
    }
  }

  int get pendingCount => _pending.length;
  int get articleCallCount => _articleCallCount;
}

List<CampusArticleSummary> _articles(
  int start,
  int count, {
  String category = '教务通知',
}) {
  return List.generate(count, (i) {
    return CampusArticleSummary(
      id: start + i,
      title: '文章${start + i}',
      category: category,
      categorySlug: 'jwtz',
      publishDate: '2026-06-20',
      authorDepartment: '教务管理科',
    );
  });
}

/// pump 几帧让 async 回调和 setState 生效，但不等待未完成的 future。
Future<void> _pumpFrames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  group('CampusArticleListScreen 分页状态机', () {
    testWidgets('快速切换分类后分页不会锁死', (tester) async {
      final service = _ControllableArticleService();

      await tester.pumpWidget(
        MaterialApp(
          home: CampusArticleListScreen(service: service),
        ),
      );
      await _pumpFrames(tester);
      expect(service.pendingCount, 1);

      // 完成"全部"第一页
      service.completeNext(CampusArticlePage(
        items: _articles(1, 25),
        page: 1,
        pageSize: 20,
        hasMore: true,
      ));
      await _pumpFrames(tester);

      // 确认第一页数据已显示
      expect(find.text('文章1'), findsOneWidget);

      // 找到垂直列表（排除水平筛选条）
      final listViewFinder = find.byWidgetPredicate(
        (w) => w is ListView && w.scrollDirection == Axis.vertical,
      );

      // 滚动到底部触发 _loadMore
      await tester.drag(listViewFinder, const Offset(0, -3000));
      await _pumpFrames(tester);

      // _loadMore 产生一个挂起请求
      expect(service.pendingCount, 1);
      final callsAfterLoadMore = service.articleCallCount;

      // 关键步骤：在"全部"第二页请求在途时，切换到"教务通知"
      // 点击筛选标签栏中的"教务通知"（排除列表项中的同名文本）
      final filterTab = find
          .ancestor(
            of: find.text('教务通知'),
            matching: find.byType(GestureDetector),
          )
          .first;
      await tester.tap(filterTab);
      await _pumpFrames(tester);

      // 切换分类触发 _loadFirstPage，产生新请求
      expect(service.articleCallCount, callsAfterLoadMore + 1);
      expect(service.pendingCount, 2);

      // 先完成旧的"全部"第二页（模拟旧请求晚返回）
      service.completeNext(CampusArticlePage(
        items: _articles(101, 20, category: '教务通知'),
        page: 2,
        pageSize: 20,
        hasMore: false,
      ));
      await _pumpFrames(tester);

      // 再完成新的"教务通知"第一页
      service.completeNext(CampusArticlePage(
        items: _articles(201, 15, category: '教务通知'),
        page: 1,
        pageSize: 20,
        hasMore: true,
      ));
      await _pumpFrames(tester);

      // 确认"教务通知"第一页已显示
      expect(find.text('文章201'), findsOneWidget);

      // 滚动到底部，验证能够触发新的 _loadMore
      await tester.drag(listViewFinder, const Offset(0, -5000));
      await _pumpFrames(tester);

      // 关键断言：应该有新的挂起请求
      // 如果 _isLoadingMore 没有被重置，articleCallCount 不会增加
      expect(
        service.articleCallCount,
        callsAfterLoadMore + 2,
        reason: '切换分类后分页不应锁死：应能发起新的 _loadMore 请求',
      );
    });

    testWidgets('分类切换后旧 _loadMore 返回不覆盖新列表内容', (tester) async {
      final service = _ControllableArticleService();

      await tester.pumpWidget(
        MaterialApp(
          home: CampusArticleListScreen(service: service),
        ),
      );
      await _pumpFrames(tester);

      // 完成"全部"第一页
      service.completeNext(CampusArticlePage(
        items: _articles(1, 25),
        page: 1,
        pageSize: 20,
        hasMore: true,
      ));
      await _pumpFrames(tester);

      final listViewFinder = find.byWidgetPredicate(
        (w) => w is ListView && w.scrollDirection == Axis.vertical,
      );

      // 滚动触发 _loadMore
      await tester.drag(listViewFinder, const Offset(0, -3000));
      await _pumpFrames(tester);
      expect(service.pendingCount, 1);

      // 切换到"教务公告"
      final filterTab = find
          .ancestor(
            of: find.text('教务公告'),
            matching: find.byType(GestureDetector),
          )
          .first;
      await tester.tap(filterTab);
      await _pumpFrames(tester);
      expect(service.pendingCount, 2);

      // 旧请求（"全部"第二页）先返回
      service.completeNext(CampusArticlePage(
        items: _articles(101, 20, category: '教务通知'),
        page: 2,
        pageSize: 20,
        hasMore: false,
      ));
      await _pumpFrames(tester);

      // 新请求（"教务公告"第一页）返回
      service.completeNext(CampusArticlePage(
        items: _articles(301, 10, category: '教务公告'),
        page: 1,
        pageSize: 20,
        hasMore: false,
      ));
      await _pumpFrames(tester);

      // 列表应只显示"教务公告"的文章
      expect(find.text('文章301'), findsOneWidget);
      expect(
        find.text('文章101'),
        findsNothing,
        reason: '旧分类的 _loadMore 结果不应出现在新分类列表中',
      );
    });
  });
}
