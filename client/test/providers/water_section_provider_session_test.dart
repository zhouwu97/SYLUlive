import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/providers/water_section_provider.dart';

Map<String, dynamic> _sectionJson(String title, {required bool followed}) {
  return {
    'id': followed ? 1 : 2,
    'slug': 'campus_life',
    'title': title,
    'is_followed': followed,
    'status': 'active',
  };
}

void main() {
  test('账号 A 的版块列表迟到时不能覆盖账号 B，旧 finally 也不能改 loading', () async {
    final firstStarted = Completer<void>();
    final firstGate = Completer<void>();
    var requestCount = 0;
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          requestCount++;
          if (requestCount == 1) {
            firstStarted.complete();
            await firstGate.future;
            handler.reject(
              DioException(requestOptions: options, message: '账号 A 旧错误'),
            );
            return;
          }
          handler.resolve(
            Response<Map<String, dynamic>>(
              requestOptions: options,
              statusCode: 200,
              data: {
                'sections': [_sectionJson('账号 B 版块', followed: false)],
              },
            ),
          );
        },
      ),
    );
    final provider = WaterSectionProvider(dio);
    addTearDown(provider.dispose);

    provider.syncSessionUser(1, 1);
    final staleLoad = provider.loadSections(forceRefresh: true);
    await firstStarted.future;

    provider.syncSessionUser(2, 2);
    final currentLoad = provider.loadSections(forceRefresh: true);
    await currentLoad;
    expect(provider.isLoading, isFalse);
    expect(provider.sections.single.title, '账号 B 版块');

    firstGate.complete();
    await staleLoad;

    expect(provider.sections.single.title, '账号 B 版块');
    expect(provider.sections.single.isFollowed, isFalse);
    expect(provider.error, isNull);
    expect(provider.isLoading, isFalse);
  });

  test('账号切换会让在途关注操作失效且不继续读取旧账号版块', () async {
    final followStarted = Completer<void>();
    final followGate = Completer<void>();
    var sectionRefreshCalls = 0;
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          if (options.method == 'POST' &&
              options.path == '/water/sections/campus_life/follow') {
            followStarted.complete();
            await followGate.future;
            handler.resolve(
              Response<void>(requestOptions: options, statusCode: 200),
            );
            return;
          }
          if (options.method == 'GET' &&
              options.path == '/water/sections/campus_life') {
            sectionRefreshCalls++;
          }
          handler.reject(
            DioException(
              requestOptions: options,
              message: 'unexpected ${options.method} ${options.path}',
            ),
          );
        },
      ),
    );
    final provider = WaterSectionProvider(dio);
    addTearDown(provider.dispose);

    provider.syncSessionUser(1, 1);
    final staleFollow = provider.toggleFollow('campus_life', true);
    await followStarted.future;
    provider.syncSessionUser(2, 2);
    followGate.complete();

    expect(await staleFollow, isFalse);
    expect(sectionRefreshCalls, 0);
    expect(provider.sections, isEmpty);
    expect(provider.error, isNull);
    expect(provider.isSaving, isFalse);
  });
}
