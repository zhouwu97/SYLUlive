import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/features/academic/domain/academic_provider.dart';
import 'package:shenliyuan/features/academic_transfer/academic_transfer_payload.dart';
import 'package:shenliyuan/features/academic_transfer/academic_transfer_service.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/course_schedule_provider.dart';
import 'package:shenliyuan/screens/academic_transfer/academic_transfer_screen.dart';

import '../helpers/golden_test_app.dart';
import '../helpers/load_test_fonts.dart';

const _session = 'AAECAwQFBgcICQoLDA0ODw';
const _webPublic =
    'BGv4XV_oRZixDKYZnsCczX013NcZX90dx3N6DGcAbvJRuVLyXuwd7tH8oZGDiZBGY1fTFK37fpdguNmvyPOala0';

// 模拟 Android 插件的去重先于扫描框过滤顺序，覆盖先扫到框外、再对准的真实操作。
class _Camera extends MobileScannerPlatform {
  final frames = StreamController<BarcodeCapture?>.broadcast(sync: true);
  StartOptions? options;
  bool permissionDenied = false;
  BarcodeCapture? galleryCapture;
  String? last;
  @override
  Stream<BarcodeCapture?> get barcodesStream => frames.stream;
  @override
  Stream<TorchState> get torchStateStream => const Stream.empty();
  @override
  Stream<double> get zoomScaleStateStream => const Stream.empty();
  @override
  Future<MobileScannerViewAttributes> start(StartOptions startOptions) async {
    options = startOptions;
    if (permissionDenied) {
      throw const MobileScannerException(
          errorCode: MobileScannerErrorCode.permissionDenied);
    }
    return const MobileScannerViewAttributes(
        cameraDirection: CameraFacing.back,
        currentTorchMode: TorchState.off,
        size: Size(1920, 1080));
  }

  @override
  Widget buildCameraView() => const ColoredBox(color: Colors.black);
  @override
  Future<void> updateScanWindow(Rect? window) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}

  @override
  Future<BarcodeCapture?> analyzeImage(
    String path, {
    List<BarcodeFormat> formats = const <BarcodeFormat>[],
  }) async =>
      galleryCapture;

  void detect(String raw, {required bool inWindow}) {
    if (options?.detectionSpeed == DetectionSpeed.noDuplicates) {
      if (last == raw) return;
      last = raw;
    }
    if (inWindow) {
      frames.add(BarcodeCapture(
          barcodes: [Barcode(rawValue: raw, format: BarcodeFormat.qrCode)]));
    }
  }
}

class _Auth extends ChangeNotifier implements AuthProvider {
  _Auth(this.user);
  @override
  User? user;
  @override
  bool get isLoggedIn => user != null;
  @override
  int accountSessionEpoch = 0;
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
  int uploadFailures = 0;
  Completer<void>? claimGate;
  final envelopes = <Map<String, dynamic>>[];
  Map<String, dynamic>? uploaded;

  Dio dio() => Dio(BaseOptions(baseUrl: 'https://sylulive.online/api'))
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
      if (path.endsWith('/claim') && claimGate != null) {
        claimGate!.future.then((_) => handler.resolve(Response(
            requestOptions: options, statusCode: 200, data: const {})));
        return;
      }
      if (path.endsWith('/payload')) {
        uploaded = jsonDecode(options.data as String) as Map<String, dynamic>;
        envelopes.add(uploaded!);
        if (uploadFailures > 0) {
          uploadFailures--;
          handler.reject(DioException(
              requestOptions: options, type: DioExceptionType.connectionError));
          return;
        }
      }
      handler.resolve(
          Response(requestOptions: options, statusCode: 200, data: const {}));
    }));
}

const _bundle = AcademicTransferBundle(
  schedules: [
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
  grades: [
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
  erke: {'categories': [], 'activities': []},
);

Future<void> _mount(WidgetTester tester, _Server server, _Loader loader,
    {User? user,
    bool camera = false,
    _Auth? auth,
    bool settle = true,
    ThemeMode themeMode = ThemeMode.light,
    TextScaler textScaler = TextScaler.noScaling,
    GlobalKey? renderKey}) async {
  await tester.pumpWidget(MultiProvider(
    providers: [
      ChangeNotifierProvider<AuthProvider>.value(
          value: auth ??
              _Auth(user ??
                  User(
                      id: 7,
                      studentId: '2403000001',
                      nickname: '测试',
                      createdAt: DateTime(2026)))),
      ChangeNotifierProvider<CourseScheduleProvider>.value(value: _Schedule()),
    ],
    child: GoldenTestApp(
      themeMode: themeMode,
      textScaler: textScaler,
      home: RepaintBoundary(
          key: renderKey,
          child: AcademicTransferScreen(
            dio: server.dio(),
            loader: loader,
            initialLink: camera
                ? null
                : const AcademicTransferLink(
                    sessionId: _session, webPublicKey: _webPublic),
          )),
    ),
  ));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  final directory = Platform.environment['QR_SYNC_QA_DIR'];
  if (directory == null) return;
  await tester.runAsync(() async {
    final image =
        await (key.currentContext!.findRenderObject()! as RenderRepaintBoundary)
            .toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(directory).create(recursive: true);
    await File('$directory/$name.png')
        .writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  setUpAll(() async {
    await loadTestFonts();
    await (FontLoader('MaterialIcons')
          ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
        .load();
  });
  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets('手机核对页实际渲染与大字号滚动：${mode.name}', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final key = GlobalKey();
      await _mount(tester, _Server(), _Loader(_bundle),
          themeMode: mode,
          textScaler: const TextScaler.linear(1.3),
          renderKey: key);
      await _capture(tester, key, 'confirm-${mode.name}');
      await tester.ensureVisible(find.text('同步到网页'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('同步到网页'));
      await tester.pumpAndSettle();
      expect(find.text('资料已发送'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('拒绝相机权限仍可粘贴链接，错误提示不被扫码遮罩覆盖', (tester) async {
    final previous = MobileScannerPlatform.instance;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final camera = _Camera()..permissionDenied = true;
    MobileScannerPlatform.instance = camera;
    addTearDown(() async {
      MobileScannerPlatform.instance = previous;
      await camera.frames.close();
    });
    final key = GlobalKey();
    await _mount(tester, _Server(), _Loader(_bundle),
        camera: true, renderKey: key);
    expect(find.text('没有相机权限'), findsOneWidget);
    expect(find.text('对准电脑网页上的二维码'), findsNothing);
    await _capture(tester, key, 'permission-denied');
    await tester.tap(find.byTooltip('粘贴同步链接'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets('Android 先在框外识别后再对准同一张二维码仍能进入核对，重复帧不重复领取', (tester) async {
    final previous = MobileScannerPlatform.instance;
    final camera = _Camera();
    MobileScannerPlatform.instance = camera;
    addTearDown(() async {
      MobileScannerPlatform.instance = previous;
      await camera.frames.close();
    });
    final server = _Server();
    await _mount(tester, server, _Loader(_bundle), camera: true);
    expect(camera.options, isNotNull);
    const raw =
        'http://127.0.0.1:5173/web/app-scan#v=1&s=$_session&k=$_webPublic';
    camera.detect(raw, inWindow: false);
    camera.detect(raw, inWindow: true);
    camera.detect(raw, inWindow: true);
    await tester.pumpAndSettle();
    expect(find.text('已连接到网页'), findsOneWidget);
    expect(server.requests.where((r) => r.path.endsWith('/claim')).length, 1);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets('扫码困难可粘贴链接，错误链接不发请求，正确链接仍须核对', (tester) async {
    final previous = MobileScannerPlatform.instance;
    final camera = _Camera();
    MobileScannerPlatform.instance = camera;
    addTearDown(() async {
      MobileScannerPlatform.instance = previous;
      await camera.frames.close();
    });
    final server = _Server();
    await _mount(tester, server, _Loader(_bundle), camera: true);
    await tester.tap(find.byTooltip('粘贴同步链接'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byType(TextField), 'https://example.invalid/other');
    await tester.tap(find.text('核对同步资料'));
    await tester.pumpAndSettle();
    expect(find.textContaining('请粘贴网页'), findsOneWidget);
    expect(server.requests, isEmpty);
    await tester.enterText(find.byType(TextField),
        'https://sylulive.online/web/app-scan#v=1&s=$_session&k=$_webPublic');
    await tester.tap(find.text('核对同步资料'));
    await tester.pumpAndSettle();
    expect(find.text('已连接到网页'), findsOneWidget);
    expect(server.uploaded, isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets('连续从相册选错二维码时每次都显示错误提示', (tester) async {
    final previous = MobileScannerPlatform.instance;
    final camera = _Camera()
      ..galleryCapture = const BarcodeCapture(barcodes: [
        Barcode(
          rawValue: 'https://example.invalid/other',
          format: BarcodeFormat.qrCode,
        ),
      ]);
    MobileScannerPlatform.instance = camera;
    const gallery = MethodChannel('plugins.flutter.io/image_picker');
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(gallery, (_) async => 'fixture.png');
    addTearDown(() async {
      messenger.setMockMethodCallHandler(gallery, null);
      MobileScannerPlatform.instance = previous;
      await camera.frames.close();
    });
    final server = _Server();
    await _mount(tester, server, _Loader(_bundle), camera: true);
    final message = find.textContaining('这不是网页课表的同步二维码');
    for (var attempt = 0; attempt < 2; attempt++) {
      await tester.tap(find.byTooltip('从相册识别'));
      await tester.pumpAndSettle();
      expect(message, findsOneWidget);
      final view =
          tester.state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger));
      view.removeCurrentSnackBar();
      await tester.pumpAndSettle();
    }
    expect(server.requests, isEmpty);
    camera.galleryCapture = const BarcodeCapture(barcodes: [
      Barcode(
        rawValue: 'https://sylulive.online/web/app-scan#v=1&s=$_session&k=$_webPublic',
        format: BarcodeFormat.qrCode,
      ),
    ]);
    await tester.tap(find.byTooltip('从相册识别'));
    await tester.pumpAndSettle();
    expect(find.text('已连接到网页'), findsOneWidget);
    expect(server.requests.where((r) => r.path.endsWith('/claim')).length, 1);
    expect(server.uploaded, isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets('上传响应丢失保留选择，重试发送同一密文且不重新扫码', (tester) async {
    final server = _Server()..uploadFailures = 1;
    await _mount(tester, server, _Loader(_bundle));
    await tester.scrollUntilVisible(find.text('同步到网页'), 120,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('同步到网页'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('同步到网页'));
    await tester.pumpAndSettle();
    expect(find.textContaining('所选资料已保留'), findsOneWidget);
    await tester.ensureVisible(find.text('重试同步'));
    await tester.tap(find.text('重试同步'));
    await tester.pumpAndSettle();
    expect(find.text('资料已发送'), findsOneWidget);
    expect(server.envelopes.length, 2);
    expect(server.envelopes[1], server.envelopes[0]);
    expect(server.requests.where((r) => r.path.endsWith('/claim')).length, 1);
    expect(
        server.requests.where((r) => r.path.endsWith('/payload')).every((r) =>
            r.extra['expectedAuthSessionEpoch'] == 0 &&
            r.extra['expectedAuthUserId'] == 7),
        isTrue);
  });

  testWidgets('同一账号重新登录也清除旧预览，禁止旧资料上传', (tester) async {
    final auth = _Auth(User(
        id: 7,
        studentId: '2403000001',
        nickname: '测试',
        createdAt: DateTime(2026)));
    final server = _Server();
    await _mount(tester, server, _Loader(_bundle), auth: auth);
    auth.accountSessionEpoch++;
    auth.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.textContaining('App 登录状态已改变'), findsOneWidget);
    expect(find.text('已连接到网页'), findsNothing);
    expect(server.uploaded, isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets('领取响应晚于离页时仍清理已领取会话，不遗留网页等待状态', (tester) async {
    final gate = Completer<void>();
    final server = _Server()..claimGate = gate;
    await _mount(tester, server, _Loader(_bundle), settle: false);
    await tester.pumpWidget(const SizedBox());
    final cancelled = server.requests.where((r) => r.method == 'DELETE').length;
    gate.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(server.requests.where((r) => r.method == 'DELETE').length,
        greaterThan(cancelled));
    expect(server.uploaded, isNull);
  });

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
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('同步到网页'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('同步到网页'));
    await tester.pumpAndSettle();

    expect(find.text('资料已发送'), findsOneWidget);
    expect(server.requests.map((r) => '${r.method} ${r.uri.path}'), [
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
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
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
