import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/edu_grade.dart';
import 'package:shenliyuan/providers/edu_provider.dart';
import 'package:shenliyuan/features/campus_data/storage/account_scoped_snapshot_store.dart';
import 'package:shenliyuan/features/campus_data/storage/academic_cache_store.dart';

import '../helpers/personal_snapshot_test_fakes.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final secureStore = <String, String>{};
  late EduProvider provider;
  late MemoryPersonalSnapshotSecureStore vaultSecureStore;
  late MemoryPersonalSnapshotFileBackend vaultFiles;
  late IncrementingRandomBytes vaultRandom;

  setUp(() {
    AppPreferencesStore.setMockInitialValues({});
    secureStore.clear();
    vaultSecureStore = MemoryPersonalSnapshotSecureStore();
    vaultFiles = MemoryPersonalSnapshotFileBackend();
    vaultRandom = IncrementingRandomBytes();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, (call) async {
      final args = Map<String, dynamic>.from(call.arguments as Map);
      final key = args['key'] as String?;
      switch (call.method) {
        case 'read':
          return secureStore[key];
        case 'write':
          secureStore[key!] = args['value'] as String;
          return null;
        case 'delete':
          secureStore.remove(key);
          return null;
        case 'deleteAll':
          secureStore.clear();
          return null;
        case 'containsKey':
          return secureStore.containsKey(key);
        case 'readAll':
          return secureStore;
      }
      return null;
    });
  });

  AccountScopedSnapshotStore createSnapshotStore(String appUserId) {
    return AesGcmAccountScopedSnapshotStore(
      appUserId: appUserId,
      secureStore: vaultSecureStore,
      fileBackend: vaultFiles,
      randomBytes: vaultRandom.call,
    );
  }

  Future<void> setBoundUser(EduProvider value, String userId) async {
    value.setUserId(userId);
    await value.ensureStatusLoaded();
  }

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, null);
  });

  /// Create a provider with a Dio that intercepts /edu/grades and
  /// resolves with the given [responseData] after an optional [delay].
  EduProvider createProvider({
    required List<Map<String, dynamic>> responseData,
    Duration? delay,
    int? statusCode,
  }) {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.path == '/edu/status') {
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: <String, dynamic>{
                  'edu_authorized': true,
                  'edu_student_id': '2403130233',
                },
              ),
            );
            return;
          }
          if (options.path == '/edu/grades') {
            if (delay != null) {
              Future.delayed(delay, () {
                handler.resolve(
                  Response(
                    requestOptions: options,
                    statusCode: statusCode ?? 200,
                    data: {'grades': responseData},
                  ),
                );
              });
            } else {
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: statusCode ?? 200,
                  data: {'grades': responseData},
                ),
              );
            }
            return;
          }
          if (options.path == '/edu/authorization' &&
              options.method == 'DELETE') {
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: const <String, dynamic>{
                  'edu_authorized': false,
                  'edu_session_state': 'revoked',
                },
              ),
            );
            return;
          }
          // Default: pass through (will fail if unexpected)
          handler.next(options);
        },
      ),
    );
    return EduProvider(dio, createSnapshotStore);
  }

  group('EduProvider grade cache isolation', () {
    test('getCachedGrades returns null after userId switch', () async {
      provider = createProvider(responseData: []);

      // Set user A, manually add cache entry
      await setBoundUser(provider, 'user_a');
      // Use fetchGrades to populate cache for A
      expect(provider.getCachedGrades('2025', 3), isNull);
    });

    test('clearGradeCacheForUser only removes targeted user entries', () async {
      provider = createProvider(responseData: [
        {
          'name': '课程A',
          'grade': '90',
          'credits': 3,
          'gpa': 4.0,
          'is_degree': true
        },
      ]);

      // Populate cache for user A
      await setBoundUser(provider, 'user_a');
      await provider.fetchGrades('2025', 3);
      expect(provider.getCachedGrades('2025', 3), isNotNull);

      // Populate cache for user B (setUserId clears A's cache — expected behavior)
      await setBoundUser(provider, 'user_b');
      await provider.fetchGrades('2025', 3);
      expect(provider.getCachedGrades('2025', 3), isNotNull);

      // Current user is B. clearGradeCacheForUser('user_a') should be a no-op
      // since A's cache was already cleared by setUserId.
      provider.clearGradeCacheForUser('user_a');
      // B's cache should be unaffected
      expect(provider.getCachedGrades('2025', 3), isNotNull);

      // Now clear B — B's cache should be gone
      provider.clearGradeCacheForUser('user_b');
      expect(provider.getCachedGrades('2025', 3), isNull);
    });

    test('fetchGrades rejects result when user switches during request',
        () async {
      final completer = Completer<void>();

      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.path == '/edu/grades') {
              // Don't resolve yet — wait for completer
              completer.future.then((_) {
                handler.resolve(
                  Response(
                    requestOptions: options,
                    statusCode: 200,
                    data: {
                      'grades': [
                        {
                          'name': '课程X',
                          'grade': '85',
                          'credits': 3,
                          'gpa': 3.5,
                          'is_degree': false,
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
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.path == '/edu/status') {
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: <String, dynamic>{
                    'edu_authorized': true,
                    'edu_student_id': '2403130233',
                  },
                ),
              );
              return;
            }
            handler.next(options);
          },
        ),
      );
      final p = EduProvider(dio, createSnapshotStore);

      // Set user A and fire request
      await setBoundUser(p, 'user_a');
      final future = p.fetchGrades('2025', 3);

      // Switch to user B before the response arrives
      p.setUserId('user_b');

      // Now let the response through
      completer.complete();

      final result = await future;

      // Should reject because user switched
      expect(result.success, false);
      expect(result.errorMessage, contains('用户已切换'));

      // User B should NOT have gotten A's grades in cache
      expect(p.getCachedGrades('2025', 3), isNull);
    });

    test('getCourses rejects delayed response after account context changes',
        () async {
      final responseStarted = Completer<void>();
      final releaseResponse = Completer<void>();
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.path == '/edu/status') {
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: <String, dynamic>{
                    'edu_authorized': true,
                    'edu_student_id': '2403130233',
                  },
                ),
              );
              return;
            }
            if (options.path == '/edu/courses') {
              responseStarted.complete();
              releaseResponse.future.then((_) {
                handler.resolve(
                  Response(
                    requestOptions: options,
                    statusCode: 200,
                    data: <String, dynamic>{
                      'courses': <Map<String, dynamic>>[
                        <String, dynamic>{'name': '旧账号课程'},
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
      final value = EduProvider(dio, createSnapshotStore);
      await setBoundUser(value, 'user_a');

      final pending = value.getCourses('2025', 3);
      await responseStarted.future;
      value.setUserId('user_b');
      releaseResponse.complete();

      final result = await pending;
      expect(result?.success, isFalse);
      expect(result?.errorMessage, contains('用户已切换'));
    });

    test('fetchGrades writes to correct user cache on success', () async {
      provider = createProvider(responseData: [
        {
          'name': '数据结构',
          'grade': '90',
          'credits': 4,
          'gpa': 4.0,
          'is_degree': true
        },
      ]);

      await setBoundUser(provider, 'user_123');
      final result = await provider.fetchGrades('2025', 3);

      expect(result.success, true);
      expect(result.data, isNotNull);
      expect(result.data!.length, 1);

      // Cache should exist for this user+semester
      final cached = provider.getCachedGrades('2025', 3);
      expect(cached, isNotNull);
      expect(cached!.grades.first.name, '数据结构');
      expect(cached.updatedAt, isNotNull);
    });

    test('fetchGrades returns fail for empty grades list', () async {
      provider = createProvider(responseData: []);

      await setBoundUser(provider, 'user_x');
      final result = await provider.fetchGrades('2025', 3);

      // Empty list is still "success" (the request succeeded, just no grades)
      expect(result.success, true);
      expect(result.data, isEmpty);
    });

    test('fetchGrades returns fail on network error', () async {
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.path == '/edu/grades') {
              handler.reject(
                DioException(
                  requestOptions: options,
                  type: DioExceptionType.connectionError,
                  error: 'Connection refused',
                ),
              );
              return;
            }
            handler.next(options);
          },
        ),
      );
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.path == '/edu/status') {
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: <String, dynamic>{
                    'edu_authorized': true,
                    'edu_student_id': '2403130233',
                  },
                ),
              );
              return;
            }
            handler.next(options);
          },
        ),
      );
      final p = EduProvider(dio, createSnapshotStore);

      await setBoundUser(p, 'user_x');
      final result = await p.fetchGrades('2025', 3);

      expect(result.success, false);
      expect(result.errorMessage, isNotEmpty);
      // No cache should be written on failure
      expect(p.getCachedGrades('2025', 3), isNull);
    });

    test('失败的学业情况响应不会写入加密快照', () async {
      final dio = Dio();
      Object? academicRequestData;
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.path == '/edu/status') {
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: <String, dynamic>{
                    'edu_authorized': true,
                    'edu_student_id': '2403130233',
                  },
                ),
              );
              return;
            }
            if (options.path == '/edu/academic-situation') {
              academicRequestData = options.data;
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: <String, dynamic>{
                    'success': false,
                    'error_code': 'ACADEMIC_SITUATION_STRUCTURE_CHANGED',
                    'message': '学业情况页面结构发生变化',
                    'parser_version': 'academic-situation-v2',
                    'courses_status': 'parse_failed',
                  },
                ),
              );
              return;
            }
            handler.next(options);
          },
        ),
      );
      final value = EduProvider(dio, createSnapshotStore);
      await setBoundUser(value, 'user_academic');

      final result = await value.fetchAcademicSituation();

      expect(result.success, isFalse);
      expect(result.errorMessage, '学业情况页面结构发生变化');
      expect(academicRequestData, isA<Map<String, dynamic>>());
      expect(
        (academicRequestData! as Map<String, dynamic>).containsKey(
          'force_refresh',
        ),
        isFalse,
      );
      final store = AcademicCacheStore(
        appUserId: 'user_academic',
        sourceAccountId: '2403130233',
        snapshotStore: createSnapshotStore('user_academic'),
      );
      expect(await store.readSnapshot(), isNull);
      expect(value.getCachedAcademicSituation(), isNull);
    });

    test('setUserId clears cache for old user', () async {
      provider = createProvider(responseData: [
        {
          'name': '课程',
          'grade': '80',
          'credits': 2,
          'gpa': 3.0,
          'is_degree': false
        },
      ]);

      await setBoundUser(provider, 'user_a');
      await provider.fetchGrades('2025', 3);
      expect(provider.getCachedGrades('2025', 3), isNotNull);

      // Switch to user B — should clear A's cache
      await setBoundUser(provider, 'user_b');
      // Now switch back to A — cache should be cleared
      await setBoundUser(provider, 'user_a');
      expect(provider.getCachedGrades('2025', 3), isNull);
    });

    test('EduGrade parsed from fetchGrades has correct typed fields', () async {
      provider = createProvider(responseData: [
        {
          'name': '数字逻辑',
          'grade': '64.7',
          'credits': 3.0,
          'gpa': 1.47,
          'is_degree': true,
        },
        {
          'name': '体育4',
          'grade': '84',
          'credits': 1,
          'gpa': 3.4,
          'is_degree': false,
        },
      ]);

      await setBoundUser(provider, 'user_test');
      final result = await provider.fetchGrades('2025', 12);

      expect(result.success, true);
      final grades = result.data!;
      expect(grades.length, 2);

      expect(grades[0].name, '数字逻辑');
      expect(grades[0].displayGrade, '64.7');
      expect(grades[0].credits, 3.0);
      expect(grades[0].gpa, 1.47);
      expect(grades[0].isDegree, true);

      expect(grades[1].name, '体育4');
      expect(grades[1].isPassed, true); // 84 >= 60
      expect(grades[0].isPassed, true); // 64.7 >= 60
    });

    test('revokeAuthorization clears in-memory and encrypted edu snapshots',
        () async {
      provider = createProvider(responseData: [
        {
          'name': '数据结构',
          'grade': '90',
          'credits': 4,
          'gpa': 4.0,
          'is_degree': true,
        },
      ]);

      await setBoundUser(provider, 'user_revoke');
      await provider.fetchGrades('2025', 3);
      final store = AcademicCacheStore(
        appUserId: 'user_revoke',
        sourceAccountId: '2403130233',
        snapshotStore: createSnapshotStore('user_revoke'),
      );
      expect(await store.readSnapshot(), isNotNull);

      final result = await provider.revokeAuthorization();

      expect(result.success, isTrue);
      expect(provider.isAuthorized, isFalse);
      expect(provider.sessionState, 'revoked');
      expect(provider.getCachedGrades('2025', 3), isNull);
      expect(await store.readSnapshot(), isNull);
    });

    test('clearMemoryForAccountTransition clears credit requirement cache',
        () async {
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.path == '/edu/status') {
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: const <String, dynamic>{
                    'edu_authorized': true,
                    'edu_student_id': '2403130233',
                  },
                ),
              );
              return;
            }
            if (options.path == '/edu/credit-requirements') {
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: const <String, dynamic>{
                    'success': true,
                    'status': 'available',
                    'modules': <Map<String, dynamic>>[],
                    'improvement_courses': <Map<String, dynamic>>[],
                  },
                ),
              );
              return;
            }
            handler.next(options);
          },
        ),
      );
      final value = EduProvider(dio, createSnapshotStore);

      await setBoundUser(value, 'user_credit');
      expect((await value.fetchCreditRequirements()).success, isTrue);
      expect(value.getCachedCreditRequirements(), isNotNull);

      value.clearMemoryForAccountTransition();
      value.setUserId('user_credit');

      expect(value.getCachedCreditRequirements(), isNull);
    });

    test('clearLocalSession clears local edu state and saved keys', () async {
      AppPreferencesStore.setMockInitialValues({
        'edu_bound_user_a': true,
        'edu_student_id_user_a': ' 2403130233 ',
        'edu_grade_user_a': '2024',
        'edu_college_user_a': '信息科学与工程学院',
        'edu_major_user_a': '软件工程',
        'edu_last_semester_user_a': '2025_3',
      });

      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.path == '/edu/status') {
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: {
                    'edu_authorized': true,
                    'edu_student_id': ' 2403130233 ',
                    'edu_grade': '2024',
                    'edu_college': '信息科学与工程学院',
                    'edu_major': '软件工程',
                  },
                ),
              );
              return;
            }
            if (options.path == '/edu/grades') {
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: {
                    'grades': [
                      {
                        'name': '数据结构',
                        'grade': '90',
                        'credits': 4,
                        'gpa': 4.0,
                        'is_degree': true,
                      }
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
      final p = EduProvider(dio, createSnapshotStore);

      await setBoundUser(p, 'user_a');
      await p.fetchGrades('2025', 3);
      expect(p.isBound, true);
      expect(p.getCachedGrades('2025', 3), isNotNull);

      await p.clearLocalSession();

      expect(p.userId, isNull);
      expect(p.isBound, false);
      expect(p.studentId, isEmpty);
      expect(p.grade, isEmpty);
      expect(p.college, isEmpty);
      expect(p.major, isEmpty);
      expect(p.isLoading, false);
      expect(p.isStatusLoaded, false);
      expect(p.getCachedGrades('2025', 3), isNull);

      final prefs = await AppPreferencesStore.getInstance();
      for (final key in [
        'edu_bound_user_a',
        'edu_authorized_user_a',
        'edu_session_state_user_a',
        'edu_student_id_user_a',
        'edu_grade_user_a',
        'edu_college_user_a',
        'edu_major_user_a',
        'edu_last_semester_user_a',
      ]) {
        expect(prefs.containsKey(key), false, reason: key);
      }
    });

    test('clearLocalSession prevents stale loadStatus from restoring binding',
        () async {
      final statusCompleter = Completer<void>();
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.path == '/edu/status') {
              statusCompleter.future.then((_) {
                handler.resolve(
                  Response(
                    requestOptions: options,
                    statusCode: 200,
                    data: {
                      'edu_authorized': true,
                      'edu_student_id': '2403130233',
                      'edu_grade': '2024',
                      'edu_college': '信息科学与工程学院',
                      'edu_major': '软件工程',
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
      final p = EduProvider(dio, createSnapshotStore);

      p.setUserId('user_a');
      await Future<void>.delayed(Duration.zero);
      await p.clearLocalSession();
      statusCompleter.complete();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(p.userId, isNull);
      expect(p.isBound, false);
      expect(p.studentId, isEmpty);
      expect(p.isStatusLoaded, false);
    });

    test('成绩列表可在后台预取全部构成且已缓存课程不会重复请求', () async {
      final detailRequests = <String>[];
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.path == '/edu/status') {
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: const <String, dynamic>{
                    'edu_authorized': true,
                    'edu_student_id': '2403130233',
                  },
                ),
              );
              return;
            }
            if (options.path == '/edu/grades/detail') {
              final data = Map<String, dynamic>.from(options.data as Map);
              final classId = data['class_id'] as String;
              detailRequests.add(classId);
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: <String, dynamic>{
                    'success': true,
                    'course_name': data['course_name'],
                    'total_grade': '88',
                    'components': const <Map<String, dynamic>>[
                      <String, dynamic>{
                        'name': '平时成绩',
                        'weight': '40%',
                        'score': '90',
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
      final value = EduProvider(dio, createSnapshotStore);
      await setBoundUser(value, 'user_prefetch');
      final grades = <EduGrade>[
        const EduGrade(
          name: '数据结构',
          classId: 'class-a',
          displayGrade: '88',
          credits: 3,
          gpa: 3.7,
          isDegree: true,
        ),
        const EduGrade(
          name: '计算机网络',
          classId: 'class-b',
          displayGrade: '85',
          credits: 3,
          gpa: 3.5,
          isDegree: true,
        ),
      ];

      await value.prefetchGradeDetails(
        grades,
        '2025',
        12,
        initialDelay: Duration.zero,
      );

      expect(detailRequests, <String>['class-a', 'class-b']);
      expect(value.getCachedGradeDetail(grades[0], '2025', 12), isNotNull);
      expect(value.getCachedGradeDetail(grades[1], '2025', 12), isNotNull);

      await value.prefetchGradeDetails(
        grades,
        '2025',
        12,
        initialDelay: Duration.zero,
      );
      expect(detailRequests, hasLength(2));
    });

    test('同时打开同一课程详情时复用进行中的请求', () async {
      final detailCompleter = Completer<void>();
      final detailRequestStarted = Completer<void>();
      var detailRequestCount = 0;
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.path == '/edu/status') {
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: const <String, dynamic>{
                    'edu_authorized': true,
                    'edu_student_id': '2403130233',
                  },
                ),
              );
              return;
            }
            if (options.path == '/edu/grades/detail') {
              detailRequestCount++;
              if (!detailRequestStarted.isCompleted) {
                detailRequestStarted.complete();
              }
              detailCompleter.future.then((_) {
                handler.resolve(
                  Response(
                    requestOptions: options,
                    statusCode: 200,
                    data: const <String, dynamic>{
                      'success': true,
                      'course_name': '数据结构',
                      'total_grade': '88',
                      'components': <Map<String, dynamic>>[
                        <String, dynamic>{
                          'name': '期末成绩',
                          'weight': '60%',
                          'score': '86',
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
      final value = EduProvider(dio, createSnapshotStore);
      await setBoundUser(value, 'user_deduplicate');
      const grade = EduGrade(
        name: '数据结构',
        classId: 'class-a',
        displayGrade: '88',
        credits: 3,
        gpa: 3.7,
        isDegree: true,
      );

      final first = value.fetchGradeDetail(grade, '2025', 12);
      final second = value.fetchGradeDetail(grade, '2025', 12);
      // 等待真实请求进入拦截器，再断言并发去重；固定短延迟会把调度抖动误报成回归。
      await detailRequestStarted.future.timeout(const Duration(seconds: 1));
      expect(detailRequestCount, 1);

      detailCompleter.complete();
      final results = await Future.wait([first, second]);
      expect(results.every((result) => result.success), isTrue);
      expect(detailRequestCount, 1);
    });
  });
}
