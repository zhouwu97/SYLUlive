import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/features/academic/domain/academic_provider.dart';
import 'package:shenliyuan/features/academic_transfer/academic_transfer_payload.dart';
import 'package:shenliyuan/features/academic_transfer/academic_transfer_service.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/course_schedule_provider.dart';
import 'package:shenliyuan/screens/academic_transfer/academic_transfer_screen.dart';

const _session = 'AAECAwQFBgcICQoLDA0ODw';
const _webPublic =
    'BGv4XV_oRZixDKYZnsCczX013NcZX90dx3N6DGcAbvJRuVLyXuwd7tH8oZGDiZBGY1fTFK37fpdguNmvyPOala0';

class _Auth extends ChangeNotifier implements AuthProvider {
  _Auth(this.user);
  @override
  User? user;
  @override
  bool get isLoggedIn => user != null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Schedule extends ChangeNotifier implements CourseScheduleProvider {
  @override
  AcademicIdentityKey? get academicIdentity => null;
  @override
  String get selectedYear => '2026';
  @override
  int get selectedSemester => 3;
  @override
  DateTime? get semesterStart => DateTime(2026, 9, 7);
  @override
  DateTime? get lastFetchedAt => null;
  @override
  List<CourseBlock> get courses => const <CourseBlock>[];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Loader extends AcademicTransferLoader {
  _Loader(this.bundle);
  final AcademicTransferBundle bundle;
  AcademicTransferContext? received;
  @override
  Future<AcademicTransferBundle> load(AcademicTransferContext context) async {
    received = context;
    return bundle;
  }
}

class _Server {
  final requests = <RequestOptions>[];
  int claimStatus = 200;
  Map<String, dynamic>? uploaded;

  Dio dio() => Dio()
    ..interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      requests.add(options);
      expect(options.headers['X-Expected-App-User'], '7');
      final path = options.path;
      if (path.endsWith('/claim') && claimStatus != 200) {
        handler.reject(DioException(
          requestOptions: options,
          response: Response(
            requestOptions: options,
            statusCode: claimStatus,
            data: {
              'code': 'TRANSFER_SESSION_NOT_FOUND',
              'message': '二维码已失效，请在网页重新生成'
            },
          ),
        ));
        return;
      }
      if (path.endsWith('/payload')) {
        uploaded = jsonDecode(options.data as String) as Map<String, dynamic>;
      }
      handler.resolve(
          Response(requestOptions: options, statusCode: 200, data: const {}));
    }));
}

final _bundle = AcademicTransferBundle(
  schedules: const [
    AcademicTransferSchedule(
        id: 'current',
        kind: 'current',
        label: '当前',
        courses: [
          {
            'id': 'c1',
            'name': '课',
            'teacher': '',
            'room': '',
            'day': 1,
            'periods': [1],
            'weeks': [1]
          },
        ]),
    AcademicTransferSchedule(
        id: 'archive:1',
        kind: 'archive',
        label: '存档',
        courses: [
          {
            'id': 'c2',
            'name': '课2',
            'teacher': '',
            'room': '',
            'day': 2,
            'periods': [1],
            'weeks': [1]
          },
        ]),
  ],
  grades: const [
    {
      'id': 'g',
      'name': '线性代数',
      'credit': 3,
      'score': '90',
      'gpa': 4.0,
      'nature': '',
      'term': ''
    },
  ],
  erke: const {'categories': [], 'activities': []},
);

Future<void> _mount(WidgetTester tester, _Server server, _Loader loader,
    {User? user}) async {
  await tester.pumpWidget(MultiProvider(
    providers: [
      ChangeNotifierProvider<AuthProvider>.value(
          value: _Auth(user ??
              User(
                  id: 7,
                  studentId: '2403000001',
                  nickname: '测试',
                  createdAt: DateTime(2026)))),
      ChangeNotifierProvider<CourseScheduleProvider>.value(value: _Schedule()),
    ],
    child: MaterialApp(
      home: AcademicTransferScreen(
        dio: server.dio(),
        loader: loader,
        initialLink: const AcademicTransferLink(
            sessionId: _session, webPublicKey: _webPublic),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('核对后只加密上传勾选的资料，服务器收到的只有密文信封', (tester) async {
    final server = _Server();
    final loader = _Loader(_bundle);
    await _mount(tester, server, loader);

    expect(loader.received?.appUserId, '7');
    expect(loader.received?.sourceAccountId, '2403000001');
    expect(find.text('已连接到网页'), findsOneWidget);
    expect(find.text('当前课表 1 门 · 其他学期和存档 1 份'), findsOneWidget);
    expect(find.text('1 门课程'), findsOneWidget);
    expect(find.text('没有考试安排'), findsOneWidget);

    // 没有资料的项不可勾选；取消成绩后只发送课表和二课。
    final exams = tester.widget<CheckboxListTile>(
        find.widgetWithText(CheckboxListTile, '考试安排'));
    expect(exams.onChanged, isNull);
    await tester.tap(find.widgetWithText(CheckboxListTile, '成绩'));
    await tester.pump();
    await tester.scrollUntilVisible(find.text('同步到网页'), 120,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('同步到网页'));
    await tester.pumpAndSettle();

    expect(find.text('已同步到网页'), findsOneWidget);
    expect(server.requests.map((r) => '${r.method} ${r.path}'), [
      'POST /api/academic-transfer/sessions/$_session/claim',
      'PUT /api/academic-transfer/sessions/$_session/payload',
    ]);
    expect(server.uploaded?.keys, ['app_public_key', 'nonce', 'ciphertext']);
    expect(jsonEncode(server.uploaded), isNot(contains('线性代数')));

    // 完成后离开页面不再作废会话。
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(server.requests.where((r) => r.method == 'DELETE'), isEmpty);
  });

  testWidgets('二维码失效时提示重新生成，不读取后续流程', (tester) async {
    final server = _Server()..claimStatus = 404;
    await _mount(tester, server, _Loader(_bundle));
    expect(find.text('同步没有完成'), findsOneWidget);
    expect(find.text('二维码已失效，请在网页重新生成'), findsOneWidget);
    expect(find.text('重新扫码'), findsOneWidget);
    expect(server.requests.where((r) => r.path.endsWith('/payload')), isEmpty);
  });

  testWidgets('核对时离开页面会作废这张二维码', (tester) async {
    final server = _Server();
    await _mount(tester, server, _Loader(_bundle));
    await tester.scrollUntilVisible(find.text('取消，不同步'), 120,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消，不同步'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(server.requests.map((r) => r.method), contains('DELETE'));
    expect(server.uploaded, isNull);
  });
}
