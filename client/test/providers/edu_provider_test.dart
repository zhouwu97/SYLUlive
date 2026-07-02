import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shenliyuan/providers/edu_provider.dart';
import 'package:shenliyuan/models/edu_grade.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final secureStore = <String, String>{};
  late EduProvider provider;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    secureStore.clear();
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
          // Default: pass through (will fail if unexpected)
          handler.next(options);
        },
      ),
    );
    return EduProvider(dio);
  }

  group('EduProvider grade cache isolation', () {
    test('getCachedGrades returns null after userId switch', () {
      provider = createProvider(responseData: []);

      // Set user A, manually add cache entry
      provider.setUserId('user_a');
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
      provider.setUserId('user_a');
      await provider.fetchGrades('2025', 3);
      expect(provider.getCachedGrades('2025', 3), isNotNull);

      // Populate cache for user B (setUserId clears A's cache — expected behavior)
      provider.setUserId('user_b');
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
      final p = EduProvider(dio);

      // Set user A and fire request
      p.setUserId('user_a');
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

      provider.setUserId('user_123');
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

      provider.setUserId('user_x');
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
      final p = EduProvider(dio);

      p.setUserId('user_x');
      final result = await p.fetchGrades('2025', 3);

      expect(result.success, false);
      expect(result.errorMessage, isNotEmpty);
      // No cache should be written on failure
      expect(p.getCachedGrades('2025', 3), isNull);
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

      provider.setUserId('user_a');
      await provider.fetchGrades('2025', 3);
      expect(provider.getCachedGrades('2025', 3), isNotNull);

      // Switch to user B — should clear A's cache
      provider.setUserId('user_b');
      // Now switch back to A — cache should be cleared
      provider.setUserId('user_a');
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

      provider.setUserId('user_test');
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

    test('clearLocalSession clears local edu state and saved keys', () async {
      SharedPreferences.setMockInitialValues({
        'edu_bound_user_a': true,
        'edu_student_id_user_a': ' 2403130233 ',
        'edu_grade_user_a': '2024',
        'edu_college_user_a': '信息科学与工程学院',
        'edu_major_user_a': '软件工程',
        'edu_last_semester_user_a': '2025_3',
      });
      secureStore['edu_pwd_2403130233'] = 'old-password';

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
                    'edu_bound': true,
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
      final p = EduProvider(dio);

      p.setUserId('user_a');
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
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
      expect(secureStore.containsKey('edu_pwd_2403130233'), false);

      final prefs = await SharedPreferences.getInstance();
      for (final key in [
        'edu_bound_user_a',
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
                      'edu_bound': true,
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
      final p = EduProvider(dio);

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
  });
}
