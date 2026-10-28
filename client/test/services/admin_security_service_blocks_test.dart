import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/services/admin_security_service.dart';
import 'package:shenliyuan/services/publish_session_scope.dart';

void main() {
  test('生效封禁跨页读取并按操作组汇总', () async {
    final dio = Dio();
    final requestedPages = <int>[];
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      expect(options.extra['expectedAuthUserId'], 7);
      expect(options.extra['expectedAuthSessionEpoch'], 1);
      final page = options.queryParameters['page'] as int;
      requestedPages.add(page);
      final rows = page == 1
          ? List.generate(
              200,
              (index) => {
                    'id': index + 1,
                    'group_id': 'group-1',
                    'source_fingerprint': 'abcd…',
                    'route_prefix': '/api/route-$index',
                    'reason': '测试封禁',
                    'created_by': 7,
                    'expires_at': '2026-09-23T00:00:00Z',
                  })
          : [
              {
                'id': 201,
                'group_id': 'group-1',
                'source_fingerprint': 'abcd…',
                'route_prefix': '/api/route-200',
                'reason': '测试封禁',
                'created_by': 7,
                'expires_at': '2026-09-23T00:00:00Z',
              }
            ];
      handler.resolve(Response(requestOptions: options, data: rows));
    }));

    final groups = await AdminSecurityService(dio).loadBlocks(
        session:
            const PublishSessionScope(accountId: 7, accountSessionEpoch: 1));
    expect(requestedPages, [1, 2]);
    expect(groups, hasLength(1));
    expect(groups.single.routePrefixes, hasLength(201));
    expect(groups.single.id, 1);
  });

  for (final legacy in [false, true]) {
    test('事件分页${legacy ? '兼容缺少总数的响应' : '按总数读取完整列表'}', () async {
      final dio = Dio();
      addTearDown(() => dio.close());
      final requests = <RequestOptions>[];
      dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
        requests.add(options);
        final page = options.queryParameters['page'] as int;
        final count = legacy
            ? page == 1
                ? 50
                : 0
            : page < 3
                ? 50
                : 1;
        handler.resolve(Response(requestOptions: options, data: {
          'items': List.generate(count, (i) => {'id': (page - 1) * 50 + i + 1}),
          if (!legacy) 'total': 101,
          if (!legacy) 'limit': 50,
        }));
      }));
      final service = AdminSecurityService(dio);
      final ids = <int>[];
      for (var page = 1;; page++) {
        final result = await service.loadEventPage(
            page: page,
            severity: 'high',
            status: 'active',
            actionable: 'true',
            session: const PublishSessionScope(
                accountId: 7, accountSessionEpoch: 1));
        ids.addAll(result.items.map((event) => event.id));
        if (!result.hasMore) break;
      }
      expect(ids, hasLength(legacy ? 50 : 101));
      expect(ids.toSet(), hasLength(ids.length));
      expect(requests, hasLength(legacy ? 2 : 3));
      for (final request in requests) {
        expect(request.extra['expectedAuthUserId'], 7);
        expect(request.extra['expectedAuthSessionEpoch'], 1);
        expect(request.queryParameters['severity'], 'high');
        expect(request.queryParameters['actionable'], 'true');
      }
    });
  }
}
