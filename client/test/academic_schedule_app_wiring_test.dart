import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/app_bootstrap.dart';
import 'package:shenliyuan/features/academic/application/academic_login_coordinator.dart';
import 'package:shenliyuan/features/academic/application/academic_session_controller.dart';
import 'package:shenliyuan/features/academic/domain/academic_provider.dart';
import 'package:shenliyuan/features/academic/storage/academic_connection_store.dart';
import 'package:shenliyuan/features/academic/storage/local_academic_account_store.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/course_schedule_provider.dart';
import 'package:shenliyuan/widgets/app_update_gate.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('schedule_app_wiring_');
  });

  for (final scenario in [
    (name: '服务器已有认证', verified: true, failVerification: false),
    (name: '旧声明自动补交认证', verified: false, failVerification: false),
    (name: '自动补交暂时失败', verified: false, failVerification: true),
  ]) {
    testWidgets('真实 MyApp 装配中${scenario.name}后保留课表及磁盘缓存', (tester) async {
      await tester.runAsync(() async {
        AppPreferencesStore.setMockInitialValues({});
        final secrets = <String, String>{};
        final messenger = tester.binding.defaultBinaryMessenger;
        const secureChannel =
            MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
        const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
        messenger.setMockMethodCallHandler(
            pathChannel, (_) async => directory.path);
        messenger.setMockMethodCallHandler(secureChannel, (call) async {
          final args = Map<String, dynamic>.from(call.arguments as Map? ?? {});
          final key = args['key'] as String?;
          switch (call.method) {
            case 'read':
              return secrets[key];
            case 'write':
              secrets[key!] = args['value'] as String;
              return null;
            case 'delete':
              secrets.remove(key);
              return null;
            case 'containsKey':
              return secrets.containsKey(key);
            case 'readAll':
              return secrets;
          }
          return null;
        });
        addTearDown(() {
          messenger.setMockMethodCallHandler(pathChannel, null);
          messenger.setMockMethodCallHandler(secureChannel, null);
        });
        const identity = AcademicIdentityKey(
            appUserId: '1001',
            providerId: AcademicProviderId.syluUndergraduate,
            studentId: 'test-student');
        final preferences = await AppPreferencesStore.getInstance();
        await LocalAcademicAccountStore(identity.appUserId, preferences)
            .commitIdentity(identity);
        final connection = AcademicConnectionStore(identity, preferences);
        await connection.setConnected(false);
        final user = User(
            id: 1001,
            studentId: '',
            nickname: '测试用户',
            createdAt: DateTime(2026),
            legalConsentsActive: false);
        var profileRequests = 0;
        var identityRequests = 0;
        var verificationRequests = 0;
        final dio = getSharedDio();
        final interceptor = InterceptorsWrapper(onRequest: (request, handler) {
          Object? data;
          if (request.path == '/user/profile') {
            profileRequests++;
            data = {
              ...user.toJson(),
              'student_id': identity.studentId,
              'student_verified': true,
            };
          } else if (request.path == '/student-identity') {
            identityRequests++;
            data = {
              'identities': [
                if (scenario.verified)
                  {
                    'provider_id': identity.providerId.value,
                    'student_id': identity.studentId,
                    'verified': true,
                    'verification_method': 'school_profile',
                  }
              ]
            };
          } else if (request.path == '/student-identity/verify-session') {
            verificationRequests++;
            if (scenario.failVerification) {
              handler.reject(DioException(
                requestOptions: request,
                type: DioExceptionType.badResponse,
                response: Response(
                  requestOptions: request,
                  statusCode: 503,
                  data: {'message': 'fixture temporarily unavailable'},
                ),
              ));
              return;
            }
            data = {
              'provider_id': identity.providerId.value,
              'student_id': identity.studentId,
              'verified': true,
              'assurance_level': 'school_verified',
              'verification_method': 'school_profile',
            };
          } else if (request.path.startsWith('/academic-account-configs')) {
            final config = {
              'provider_id': identity.providerId.value,
              'student_id': identity.studentId,
              'state': 'active',
              'revision': 1,
            };
            data = request.method == 'GET'
                ? {'configs': [config]}
                : {'config': config};
          }
          if (data == null) {
            handler.reject(DioException(
                requestOptions: request,
                type: DioExceptionType.connectionError));
          } else {
            handler.resolve(
                Response(requestOptions: request, statusCode: 200, data: data));
          }
        });
        dio.interceptors.insert(0, interceptor);
        addTearDown(() => dio.interceptors.remove(interceptor));
        await tester.pumpWidget(const MyApp());
        final context = tester.element(find.byType(AppUpdateGate));
        final auth = context.read<AuthProvider>();
        await auth.initializeStoredAuth();
        await auth.applyAuthPayload('fixture-token', user.toJson());
        await tester.pump();
        final session = context.read<AcademicSessionController>();
        await session.prepareAccountContext();
        await tester.pump();
        final schedule = context.read<CourseScheduleProvider>();
        await schedule.retryLocalRestore();
        await schedule.applyFetchedCourses([
          {
            'name': '回归课表',
            'course_code': 'TEST',
            'weekday': 1,
            'start_section': 1,
            'end_section': 2,
            'weeks': [1, 2],
          }
        ]);
        await tester.pump();
        expect(schedule.courses.map((course) => course.name), ['回归课表']);
        final generation = schedule.contextGeneration;
        final epoch = auth.accountSessionEpoch;
        await connection.setConnected(true);
        await connection.setBindingSyncState(AcademicBindingSyncState.declared);
        final coordinator = AcademicLoginCoordinator(
          controller: session,
          sessionExporter: () async => ProviderSessionArtifact(
            providerId: identity.providerId,
            studentId: identity.studentId,
            artifactVersion: 1,
            createdAt: DateTime.now(),
            validatedAt: DateTime.now(),
            opaqueProviderState: {
              'cookies': ['SID=fixture']
            },
          ),
        );
        addTearDown(coordinator.dispose);
        await coordinator.synchronizeIdentityBinding();
        await tester.pump();
        expect(identityRequests, greaterThan(0));
        expect(verificationRequests, scenario.verified ? 0 : 1);
        if (!scenario.failVerification) {
          expect(profileRequests, greaterThan(0));
          expect(auth.user?.studentId, identity.studentId);
          expect(auth.user?.studentVerified, true);
          expect(
              connection.bindingSyncState, AcademicBindingSyncState.verified);
        } else {
          expect(connection.bindingSyncState, AcademicBindingSyncState.pending);
        }
        expect(auth.accountSessionEpoch, epoch);
        expect(schedule.contextGeneration, generation);
        expect(schedule.courses.map((course) => course.name), ['回归课表']);
        await schedule.retryLocalRestore();
        expect(schedule.courses.map((course) => course.name), ['回归课表']);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    });
  }
}
