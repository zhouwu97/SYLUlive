import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/campus_data/storage/account_scoped_snapshot_store.dart';
import 'package:shenliyuan/features/campus_data/storage/schedule_cache_store.dart';
import 'package:shenliyuan/providers/course_schedule_provider.dart';

import 'helpers/personal_snapshot_test_fakes.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MemoryPersonalSnapshotSecureStore secureStore;
  late MemoryPersonalSnapshotFileBackend files;
  late IncrementingRandomBytes random;

  setUp(() {
    AppPreferencesStore.setMockInitialValues({});
    secureStore = MemoryPersonalSnapshotSecureStore();
    files = MemoryPersonalSnapshotFileBackend();
    random = IncrementingRandomBytes();
  });

  AccountScopedSnapshotStore createSnapshotStore(String appUserId) {
    return AesGcmAccountScopedSnapshotStore(
      appUserId: appUserId,
      secureStore: secureStore,
      fileBackend: files,
      randomBytes: random.call,
    );
  }

  CourseScheduleProvider createProvider([Dio? dio]) {
    return CourseScheduleProvider(dio, createSnapshotStore);
  }

  test('onlyCache load ends immediately when no course cache exists', () async {
    final provider = createProvider()..syncSessionContext('1001', '2403130233');

    await provider.loadCourses(onlyCache: true);

    expect(provider.isLoading, isFalse);
    expect(provider.courses, isEmpty);
    expect(provider.gridData, isEmpty);
  });

  test('来源账号延迟恢复后自动进入 ready 并读取对应会话缓存', () async {
    final seed = createProvider()..syncSessionContext('1001', '2403130233');
    await seed.applyFetchedCourses([
      {
        'name': '线性代数',
        'time': 1,
        'end_time': 2,
        'week_day': 2,
        'weeks': [1, 2, 3],
      },
    ]);

    final provider = createProvider()..syncSessionContext('1001', '');
    expect(provider.sessionPhase, ScheduleSessionPhase.resolvingIdentity);
    expect(provider.isSessionReady, isFalse);

    final generationBeforeSource = provider.contextGeneration;
    provider.syncSessionContext('1001', '2403130233');
    expect(provider.contextGeneration, greaterThan(generationBeforeSource));
    expect(provider.sessionKey, '1001::2403130233');

    for (var i = 0; i < 20 && !provider.isSessionReady; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }

    expect(provider.isSessionReady, isTrue);
    expect(provider.sessionPhase, ScheduleSessionPhase.ready);
    expect(provider.courses, hasLength(1));
    expect(provider.courses.single.name, '线性代数');
  });

  test(
      'fetched courses are available from cache for the same user and semester',
      () async {
    final provider = createProvider()..syncSessionContext('1001', '2403130233');

    await provider.applyFetchedCourses([
      {
        'name': '高等数学',
        'teacher': '王老师',
        'location': 'A101',
        'time': 1,
        'end_time': 2,
        'week_day': 1,
        'weeks': [1, 2, 3],
      },
    ]);

    final reloaded = createProvider()..syncSessionContext('1001', '2403130233');
    final loaded = await reloaded.loadCachedCoursesIfAvailable();

    expect(loaded, isTrue);
    expect(reloaded.isLoading, isFalse);
    expect(reloaded.courses, hasLength(1));
    expect(reloaded.courses.single.name, '高等数学');
  });

  test('来源学号变化后不读取旧课表缓存', () async {
    final provider = createProvider()..syncSessionContext('1001', '2403130233');
    await provider.applyFetchedCourses(<Map<String, dynamic>>[
      <String, dynamic>{
        'name': '数据结构',
        'time': 1,
        'end_time': 2,
        'week_day': 1,
        'weeks': <int>[1, 2],
      },
    ]);

    final changedSource = createProvider()
      ..syncSessionContext('1001', '2403130234');
    final loaded = await changedSource.loadCachedCoursesIfAvailable();

    expect(loaded, isFalse);
    expect(changedSource.courses, isEmpty);
  });

  test('延迟课表响应在换号后不会写入新账号或恢复旧界面', () async {
    final requestStarted = Completer<void>();
    final releaseResponse = Completer<void>();
    var requestedServerCourseCache = false;
    Duration? requestedReceiveTimeout;
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.path == '/edu/courses/local') {
            requestedServerCourseCache = true;
            handler.reject(
              DioException(
                requestOptions: options,
                type: DioExceptionType.unknown,
                error: StateError('不应访问服务端课表持久化副本'),
              ),
            );
            return;
          }
          if (options.path == '/edu/courses') {
            requestedReceiveTimeout = options.receiveTimeout;
            requestStarted.complete();
            releaseResponse.future.then((_) {
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: <String, dynamic>{
                    'success': true,
                    'courses': <Map<String, dynamic>>[
                      <String, dynamic>{
                        'name': '旧账号课程',
                        'time': 1,
                        'end_time': 2,
                        'week_day': 1,
                        'weeks': <int>[1],
                      },
                    ],
                  },
                ),
              );
            });
            return;
          }
          handler.next(options);
        },
      ),
    );
    final provider = createProvider(dio)
      ..syncSessionContext('1001', '2403130233');

    final pending = provider.loadCourses(forceRefresh: true);
    await requestStarted.future;
    provider.syncSessionContext('2002', '2403130234');
    releaseResponse.complete();
    await pending;

    expect(provider.courses, isEmpty);
    final oldStore = ScheduleCacheStore(
      appUserId: '1001',
      sourceAccountId: '2403130233',
      snapshotStore: createSnapshotStore('1001'),
    );
    final newStore = ScheduleCacheStore(
      appUserId: '2002',
      sourceAccountId: '2403130234',
      snapshotStore: createSnapshotStore('2002'),
    );
    expect(await oldStore.readTerm(year: '2025', semester: 12), isNull);
    expect(await newStore.readTerm(year: '2025', semester: 12), isNull);
    expect(requestedServerCourseCache, isFalse);
    expect(requestedReceiveTimeout, const Duration(seconds: 25));
  });

  test('课程获取成功但保险箱写入失败时明确提示未持久化', () async {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.path == '/edu/courses') {
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: <String, dynamic>{
                  'success': true,
                  'courses': <Map<String, dynamic>>[
                    <String, dynamic>{
                      'name': '数据结构',
                      'time': 1,
                      'end_time': 2,
                      'week_day': 1,
                      'weeks': <int>[1, 2],
                    },
                  ],
                },
              ),
            );
            return;
          }
          handler.next(options);
        },
      ),
    );
    files.failWrites = true;
    final provider = createProvider(dio)
      ..syncSessionContext('1001', '2403130233');

    await provider.loadCourses(forceRefresh: true);

    expect(provider.courses.single.name, '数据结构');
    expect(provider.errorMessage, '课程已获取，但未能安全保存，请稍后重试');
    expect(provider.isLoading, isFalse);
  });
}
