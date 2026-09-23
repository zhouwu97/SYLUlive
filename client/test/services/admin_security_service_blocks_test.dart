import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/services/admin_security_service.dart';

void main() {
  test('生效封禁跨页读取并按操作组汇总', () async {
    final dio = Dio();
    final requestedPages = <int>[];
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
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

    final groups = await AdminSecurityService(dio).loadBlocks();
    expect(requestedPages, [1, 2]);
    expect(groups, hasLength(1));
    expect(groups.single.routePrefixes, hasLength(201));
    expect(groups.single.id, 1);
  });
}
