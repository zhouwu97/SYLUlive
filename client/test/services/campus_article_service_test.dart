import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/services/campus_article_service.dart';

/// 构造一个包含指定字符串的 [ResponseBody]。
ResponseBody _responseBody(String text, int statusCode,
    {String contentType = 'application/json'}) {
  return ResponseBody(
    Stream.value(utf8.encode(text)),
    statusCode,
    headers: {
      Headers.contentTypeHeader: [contentType],
    },
  );
}

/// 简单的 Dio mock 适配器，按路径返回预设响应。
class _MockAdapter implements HttpClientAdapter {
  final Map<String, _MockResponse> _responses = {};

  void register(String method, String path, _MockResponse response) {
    _responses['$method:$path'] = response;
  }

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final key = '${options.method}:${options.path}';
    final mock = _responses[key];

    if (mock == null) {
      return _responseBody('{"error": "not mocked: $key"}', 500);
    }

    // 模拟超时
    if (mock.simulateTimeout) {
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.connectionTimeout,
      );
    }

    // 模拟非 JSON 响应
    if (mock.rawBody != null) {
      return _responseBody(mock.rawBody!, mock.statusCode,
          contentType: mock.contentType);
    }

    return _responseBody(mock.body ?? '{}', mock.statusCode);
  }
}

class _MockResponse {
  final int statusCode;
  final String? body;
  final String? rawBody;
  final String contentType;
  final bool simulateTimeout;

  _MockResponse({
    required this.statusCode,
    this.body,
    this.rawBody,
    this.contentType = 'application/json',
    this.simulateTimeout = false,
  });
}

void main() {
  late Dio dio;
  late _MockAdapter adapter;
  late CampusArticleService service;

  setUp(() {
    dio = Dio(BaseOptions(baseUrl: 'http://test.local/api'));
    adapter = _MockAdapter();
    dio.httpClientAdapter = adapter;
    service = CampusArticleService(dio);
  });

  group('getLatestArticle', () {
    test('成功返回最新文章摘要', () async {
      adapter.register(
          'GET',
          '/campus/articles/latest',
          _MockResponse(
            statusCode: 200,
            body: '''{
          "item": {
            "id": 1,
            "source": "jwc",
            "category": "教务通知",
            "category_slug": "jwtz",
            "title": "最新通知标题",
            "publish_date": "2026-06-23",
            "author_department": "教务管理科",
            "source_url": "https://jwc.sylu.edu.cn/jwtz/1.htm",
            "has_attachment": true,
            "content_text": "正文内容",
            "content_html": "<p>正文</p>",
            "attachments": []
          }
        }''',
          ));

      final result = await service.getLatestArticle();
      expect(result, isNotNull);
      expect(result!.id, 1);
      expect(result.title, '最新通知标题');
      expect(result.category, '教务通知');
    });

    test('item 为 null 时返回 null', () async {
      adapter.register(
          'GET',
          '/campus/articles/latest',
          _MockResponse(
            statusCode: 200,
            body: '{"item": null}',
          ));

      final result = await service.getLatestArticle();
      expect(result, isNull);
    });

    test('非 JSON 响应抛出 ServiceException', () async {
      adapter.register(
          'GET',
          '/campus/articles/latest',
          _MockResponse(
            statusCode: 200,
            rawBody: 'Internal Server Error',
            contentType: 'text/plain',
          ));

      expect(
        () => service.getLatestArticle(),
        throwsA(isA<CampusArticleServiceException>()),
      );
    });
  });

  group('getArticles', () {
    test('成功返回分页列表', () async {
      adapter.register(
          'GET',
          '/campus/articles',
          _MockResponse(
            statusCode: 200,
            body: '''{
          "items": [
            {"id": 1, "title": "第一篇", "category": "教务通知", "category_slug": "jwtz"},
            {"id": 2, "title": "第二篇", "category": "教务公告", "category_slug": "jwgg"}
          ],
          "page": 1,
          "page_size": 20,
          "has_more": true,
          "last_sync_at": "2026-06-23T10:00:00+08:00"
        }''',
          ));

      final page = await service.getArticles(page: 1, pageSize: 20);
      expect(page.items.length, 2);
      expect(page.items[0].id, 1);
      expect(page.items[1].category, '教务公告');
      expect(page.hasMore, true);
    });

    test('has_more 为 false 时正确解析', () async {
      adapter.register(
          'GET',
          '/campus/articles',
          _MockResponse(
            statusCode: 200,
            body: '''{
          "items": [{"id": 1, "title": "唯一一篇"}],
          "page": 1,
          "page_size": 20,
          "has_more": false
        }''',
          ));

      final page = await service.getArticles();
      expect(page.items.length, 1);
      expect(page.hasMore, false);
    });

    test('500 服务器错误抛出 DioException', () async {
      adapter.register(
          'GET',
          '/campus/articles',
          _MockResponse(
            statusCode: 500,
            body: '{"error": "查询失败"}',
          ));

      expect(
        () => service.getArticles(),
        throwsA(isA<DioException>()),
      );
    });
  });

  group('getArticleDetail', () {
    test('成功返回文章详情', () async {
      adapter.register(
          'GET',
          '/campus/articles/42',
          _MockResponse(
            statusCode: 200,
            body: '''{
          "item": {
            "id": 42,
            "title": "详情测试",
            "category": "教务通知",
            "category_slug": "jwtz",
            "publish_date": "2026-06-20",
            "author_department": "教务科",
            "source_url": "https://jwc.sylu.edu.cn/jwtz/42.htm",
            "has_attachment": true,
            "content_text": "完整正文内容",
            "content_html": "<p>完整正文</p>",
            "attachments": [
              {"name": "附件.doc", "url": "https://jwc.sylu.edu.cn/a.doc", "extension": "doc"}
            ]
          }
        }''',
          ));

      final detail = await service.getArticleDetail(42);
      expect(detail.id, 42);
      expect(detail.title, '详情测试');
      expect(detail.contentText, '完整正文内容');
      expect(detail.attachments.length, 1);
      expect(detail.attachments.first.name, '附件.doc');
    });

    test('404 文章不存在抛出 DioException', () async {
      adapter.register(
          'GET',
          '/campus/articles/999',
          _MockResponse(
            statusCode: 404,
            body: '{"error": "文章不存在"}',
          ));

      expect(
        () => service.getArticleDetail(999),
        throwsA(isA<DioException>()),
      );
    });

    test('超时抛出 DioException', () async {
      adapter.register(
          'GET',
          '/campus/articles/1',
          _MockResponse(
            statusCode: 200,
            simulateTimeout: true,
          ));

      expect(
        () => service.getArticleDetail(1),
        throwsA(isA<DioException>()),
      );
    });
  });
}
