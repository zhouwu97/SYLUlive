import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:shenliyuan/features/theme_pack/admin_theme_review_screen.dart';
import 'package:shenliyuan/features/theme_pack/installed_themes_screen.dart';
import 'package:shenliyuan/features/theme_pack/theme_beta_notice.dart';
import 'package:shenliyuan/features/theme_pack/theme_manifest.dart';
import 'package:shenliyuan/features/theme_pack/theme_pack_codec.dart';
import 'package:shenliyuan/features/theme_pack/theme_pack_store.dart';
import 'package:shenliyuan/features/theme_pack/theme_store_repository.dart';
import 'package:shenliyuan/features/theme_pack/theme_store_screen.dart';
import 'package:shenliyuan/features/theme_pack/theme_submission_screen.dart';
import 'package:shenliyuan/features/theme_pack/theme_trial_banner.dart';
import 'package:shenliyuan/features/theme_pack/theme_workshop_screen.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/services/publish_session_scope.dart';

import '../helpers/load_test_fonts.dart';

class _TestAuth extends AuthProvider {
  _TestAuth(super.dio, {int id = 1, String role = 'user'})
      : active = User(
          id: id,
          studentId: '2026000$id',
          nickname: '测试用户$id',
          role: role,
          createdAt: DateTime(2026),
        ),
        super(loadStoredAuth: false);

  int epoch = 1;
  User? active;

  @override
  User? get user => active;

  @override
  bool get isLoggedIn => active != null;

  @override
  String? get token => active == null ? null : 'tok-${active!.id}';

  @override
  int get accountSessionEpoch => epoch;

  void switchUser({required int id, String role = 'user'}) {
    active = User(
      id: id,
      studentId: '2026000$id',
      nickname: '测试用户$id',
      role: role,
      createdAt: DateTime(2026),
    );
    epoch++;
    notifyListeners();
  }
}

ThemeCatalogItem _fakeCatalogItem({
  String familyId = '11111111-2222-4333-8444-555555555555',
  int version = 1,
  String name = '海盐蓝',
  String source = 'community',
  String packageUrl = '/custom-cdn/exact-pack-v1.sltheme',
  int packageSize = 0,
  String packageSha256 = '',
  String minAppVersion = '1.0.0',
}) {
  return ThemeCatalogItem(
    familyId: familyId,
    version: version,
    name: name,
    description: '清爽蓝白主题',
    license: 'CC-BY-4.0',
    author: const ThemeCatalogAuthor(
      id: 1,
      nickname: '海盐作者',
      avatarUrl: '',
    ),
    tags: const ['清新', '浅色'],
    source: source,
    previewLight: '',
    previewDark: '',
    packageUrl: packageUrl,
    packageSize: packageSize,
    packageSha256: packageSha256,
    minAppVersion: minAppVersion,
    downloads: 12,
    updatedAt: '2026-11-18T00:00:00Z',
  );
}

Future<Uint8List> _buildValidPackBytes({
  String? id,
  int version = 1,
  String name = '海盐蓝',
  String seedHex = '#2F7FD8',
  bool immersiveAndDecorated = false,
}) async {
  Directory? assetDir;
  try {
    final state = ThemeWorkshopStateData.fromDefault(seedHex: seedHex);
    if (id != null) state.themeId = id;
    state.version = version;
    state.name = name;
    state.author = '海盐作者';
    state.description = '包含沉浸页头与透明贴纸的测试主题';
    state.tags = ['清新', '明暗自适应'];
    state.license = 'CC-BY-4.0';

    if (immersiveAndDecorated) {
      assetDir = await Directory.systemTemp.createTemp('sltheme-p4-assets-');
      final wallImg = img.Image(width: 320, height: 480);
      img.fill(wallImg, color: img.ColorRgb8(230, 242, 255));
      final wallPath = p.join(assetDir.path, 'wall.png');
      await File(wallPath).writeAsBytes(img.encodePng(wallImg));

      final sticker1 = img.Image(width: 96, height: 96, numChannels: 4);
      img.fillCircle(
        sticker1,
        x: 48,
        y: 48,
        radius: 36,
        color: img.ColorRgba8(47, 127, 216, 180),
      );
      final sticker1Path = p.join(assetDir.path, 's1.png');
      await File(sticker1Path).writeAsBytes(img.encodePng(sticker1));

      final sticker2 = img.Image(width: 96, height: 96, numChannels: 4);
      img.fillRect(
        sticker2,
        x1: 16,
        y1: 16,
        x2: 80,
        y2: 80,
        color: img.ColorRgba8(20, 124, 114, 210),
      );
      final sticker2Path = p.join(assetDir.path, 's2.png');
      await File(sticker2Path).writeAsBytes(img.encodePng(sticker2));

      state.layout['home'] = {
        'preset': 'immersive',
        'alignment': 'center',
        'imageHeight': 176.0,
        'imageWidth': 0.92,
      };
      state.light.cardStyle = {'borderWidth': 1.5, 'shadow': 'soft'};
      state.light.wallpapers['global'] = {
        'portrait': wallPath,
        'fit': 'cover',
        'focalX': 0.5,
        'focalY': 0.5,
        'blur': 2.0,
        'scrim': 0.12,
        'adjustments': {
          'brightness': 12.0,
          'contrast': 110.0,
          'saturation': 108.0,
        },
      };
      state.light.decorations['home'] = {
        'background': {
          'image': wallPath,
          'fit': 'cover',
          'focalX': 0.5,
          'focalY': 0.5,
          'scrim': 0.15,
          'adjustments': {
            'brightness': -5.0,
            'contrast': 105.0,
            'saturation': 95.0,
          },
        },
        'stickers': [
          {
            'image': sticker1Path,
            'x': 0.82,
            'y': 0.18,
            'width': 0.16,
            'rotation': 12.0,
          },
          {
            'image': sticker2Path,
            'x': 0.14,
            'y': 0.78,
            'width': 0.14,
            'rotation': -8.0,
          },
        ],
      };
    }

    expect(state.checkAllContrast(), isEmpty);
    return await state.exportPack(appVersion: '1.7.12');
  } finally {
    if (assetDir != null && await assetDir.exists()) {
      await assetDir.delete(recursive: true);
    }
  }
}

Future<void> _settleIo(WidgetTester tester, {int cycles = 8}) async {
  for (var i = 0; i < cycles; i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 25));
  }
  await tester.pump(const Duration(milliseconds: 350));
}

Future<void> _waitKey(WidgetTester tester, Key key) async {
  for (var i = 0; i < 40 && find.byKey(key).evaluate().isEmpty; i++) {
    await _settleIo(tester, cycles: 2);
  }
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
}

Widget _wrapWithProviders({
  required _TestAuth auth,
  required ThemeProvider themeProvider,
  required Widget home,
}) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AuthProvider>.value(value: auth),
      ChangeNotifierProvider<ThemeProvider>.value(value: themeProvider),
    ],
    child: MaterialApp(
      theme: themeProvider.buildAppTheme(Brightness.light),
      darkTheme: themeProvider.buildAppTheme(Brightness.dark),
      builder: (context, child) => ThemeTrialBannerHost(
        child: child ?? const SizedBox.shrink(),
      ),
      home: home,
    ),
  );
}

class _GoLoopbackServer {
  _GoLoopbackServer._(this.process, this.baseUrl, this.tokens);

  final Process process;
  final String baseUrl;
  final Map<String, String> tokens;

  static Future<_GoLoopbackServer> start() async {
    final serverDir = p.normalize(p.join(Directory.current.path, '..', 'server'));
    final proc = await Process.start(
      'go',
      const [
        'test',
        '-count=1',
        '-v',
        './cmd',
        '-run',
        r'^TestThemeLoopbackHarness$',
      ],
      workingDirectory: serverDir,
      environment: {
        ...Platform.environment,
        'SYLU_THEME_LOOPBACK_HARNESS': '1',
      },
    );

    final readyCompleter = Completer<Map<String, dynamic>>();
    final logBuf = StringBuffer();

    proc.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      logBuf.writeln(line);
      const marker = 'HARNESS_READY ';
      final idx = line.indexOf(marker);
      if (idx >= 0 && !readyCompleter.isCompleted) {
        final payload =
            jsonDecode(line.substring(idx + marker.length)) as Map<String, dynamic>;
        readyCompleter.complete(payload);
      }
    });
    proc.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(logBuf.writeln);

    unawaited(proc.exitCode.then((code) {
      if (!readyCompleter.isCompleted) {
        readyCompleter.completeError(
          StateError('Go loopback server exited early ($code):\n$logBuf'),
        );
      }
    }));

    final payload = await readyCompleter.future.timeout(
      const Duration(seconds: 90),
      onTimeout: () {
        proc.kill();
        throw TimeoutException('Timed out starting Go loopback server:\n$logBuf');
      },
    );
    final rawTokens = Map<String, dynamic>.from(payload['tokens'] as Map);
    return _GoLoopbackServer._(
      proc,
      payload['baseUrl'] as String,
      rawTokens.map((k, v) => MapEntry(k, v.toString())),
    );
  }

  Dio clientFor(String tokenKey) {
    final token = tokens[tokenKey];
    return Dio(
      BaseOptions(
        baseUrl: baseUrl,
        headers: token == null ? null : {'Authorization': 'Bearer $token'},
      ),
    );
  }

  Future<void> stop() async {
    try {
      final stopUrl = baseUrl.replaceFirst(RegExp(r'/api$'), '/__harness/stop');
      await Dio().postUri<void>(Uri.parse(stopUrl)).timeout(
            const Duration(seconds: 2),
          );
    } catch (_) {}
    try {
      await process.exitCode.timeout(const Duration(seconds: 5));
    } catch (_) {
      process.kill();
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late final HttpOverrides? defaultTestHttpOverrides;
  late Uint8List sharedPackBytes;
  late ThemeManifest sharedPackManifest;
  late String sharedPackSha256;

  setUpAll(() async {
    defaultTestHttpOverrides = HttpOverrides.current;
    await loadTestFonts();
    await (FontLoader('MaterialIcons')
          ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
        .load();
    sharedPackBytes = await _buildValidPackBytes(
      id: '11111111-2222-4333-8444-555555555555',
      version: 1,
      name: '海盐蓝',
    );
    final decoded =
        await ThemePackCodec.decode(sharedPackBytes, appVersion: '1.7.12');
    sharedPackManifest = decoded.manifest;
    sharedPackSha256 = sha256.convert(sharedPackBytes).toString();
  });

  late Directory temp;
  late ThemePackStore store;
  late ThemeProvider themeProvider;

  setUp(() async {
    HttpOverrides.global = defaultTestHttpOverrides;
    temp = await Directory.systemTemp.createTemp('sltheme-store-test-');
    store = ThemePackStore(directory: Directory(p.join(temp.path, 'themes')));
    AppPreferencesStore.setCustomInstance(MemoryPreferencesStore());
    themeProvider = ThemeProvider(loadOnStart: false, themePackStore: store);
    await themeProvider.loadThemeForTesting();
  });

  tearDown(() async {
    HttpOverrides.global = defaultTestHttpOverrides;
    themeProvider.dispose();
    AppPreferencesStore.setCustomInstance(null);
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    for (var attempt = 0; attempt < 5; attempt++) {
      if (!await temp.exists()) break;
      try {
        await temp.delete(recursive: true);
        break;
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 60));
      }
    }
  });

  testWidgets('主题 Beta 默认应用、失败重试、跳转恢复与再次启动',
      (tester) async {
    PackageInfo.setMockInitialValues(
      appName: '沈理校园',
      packageName: 'com.shenliyuan.app',
      version: '1.7.12',
      buildNumber: '1722',
      buildSignature: '',
    );
    final familyId = sharedPackManifest.id;
    final dio = Dio(BaseOptions(baseUrl: 'https://fixture.test/api'));
    final auth = _TestAuth(dio);
    addTearDown(auth.dispose);
    final firstRequest = Completer<void>();
    var loads = 0;
    final bundle = _BetaAssetBundle(() async {
      if (++loads == 1) {
        await firstRequest.future;
        throw StateError('主题文件不可读');
      }
      return ByteData.sublistView(sharedPackBytes);
    });

    Widget app() => _wrapWithProviders(
          auth: auth,
          themeProvider: themeProvider,
          home: DefaultAssetBundle(
            bundle: bundle,
            child: const ThemeBetaNotice(child: Scaffold(body: Text('首页'))),
          ),
        );

    await tester.pumpWidget(app());
    await _settleIo(tester, cycles: 2);
    expect(find.text('正在加载「明风」主题…'), findsOneWidget);
    expect(find.text('首页'), findsOneWidget);
    firstRequest.complete();
    await _settleIo(tester, cycles: 2);
    expect(find.text('「明风」主题加载失败，仍在使用当前外观。'), findsOneWidget);
    expect(themeProvider.hasThemeColors, isFalse);

    await tester.tap(find.text('重试'));
    for (var i = 0;
        i < 55 && find.text('前往主题设置').evaluate().isEmpty;
        i++) {
      await _settleIo(tester, cycles: 2);
    }
    expect(themeProvider.isThemeVersionActive(familyId, 1), isTrue);
    expect(find.textContaining('Beta 测试'), findsOneWidget);
    expect(
      await tester.runAsync(
        () => themeProvider.applyInstalledTheme(
          InstalledTheme(sharedPackManifest, temp.path, ''),
          {ThemeGroup.colors},
          asBetaDefault: true,
        ),
      ),
      isFalse,
    );
    await tester.tap(find.text('前往主题设置'));
    await tester.pumpAndSettle();
    expect(find.text('界面设置'), findsOneWidget);
    await tester.tap(find.text('恢复上一个外观'));
    await _settleIo(tester);
    expect(themeProvider.hasThemeColors, isFalse);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(app());
    await _settleIo(tester, cycles: 2);
    expect(find.textContaining('Beta 测试'), findsNothing);
    expect(loads, 2);
  });

  test('分享深链解析、游标分页、ETag 304 缓存命中与批量更新查询', () async {
    const id = '11111111-2222-4333-8444-555555555555';
    expect(ThemeShareLink.parseFamilyId('sylulive://theme/$id'), id);
    expect(
      ThemeShareLink.parseFamilyId('https://sylulive.online/theme/$id'),
      id,
    );
    expect(ThemeShareLink.parseFamilyId('sylulive://theme/not-a-uuid'), isNull);
    expect(
      ThemeShareLink.parseFamilyId('https://example.com/theme/$id'),
      isNull,
    );

    final dio = Dio(BaseOptions(baseUrl: 'https://fixture.test/api'));
    final seenIfNoneMatch = <String?>[];
    var hitCount = 0;

    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          hitCount++;
          seenIfNoneMatch.add(options.headers['If-None-Match'] as String?);
          if (options.queryParameters['ids'] != null) {
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                headers: Headers.fromMap({'etag': ['"etag-ids"']}),
                data: {
                  'items': [
                    {
                      'familyId': id,
                      'version': 2,
                      'name': '海盐蓝',
                      'packageUrl': '/api/themes/$id/versions/2/package',
                      'packageSize': sharedPackBytes.length,
                      'packageSha256': sharedPackSha256,
                      'minAppVersion': '1.0.0',
                    }
                  ],
                },
              ),
            );
            return;
          }
          if (options.headers['If-None-Match'] == '"etag-p1"') {
            handler.resolve(
              Response(requestOptions: options, statusCode: 304),
            );
            return;
          }
          final cursor = options.queryParameters['cursor'] as String?;
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              headers: Headers.fromMap({
                'etag': [cursor == null ? '"etag-p1"' : '"etag-p2"'],
              }),
              data: {
                'items': [
                  {
                    'familyId': cursor == null
                        ? id
                        : '22222222-3333-4444-8555-666666666666',
                    'version': 1,
                    'name': cursor == null ? '第一页主题' : '第二页主题',
                    'packageUrl': '/cdn/p1.sltheme',
                    'packageSize': 1024,
                    'packageSha256': sharedPackSha256,
                    'minAppVersion': '1.0.0',
                  },
                ],
                if (cursor == null) 'nextCursor': 'cursor-page-2',
              },
            ),
          );
        },
      ),
    );

    final repo = ThemeStoreRepository(dio);
    final page1 = await repo.listCatalog();
    expect(page1.items.single.name, '第一页主题');
    expect(page1.nextCursor, 'cursor-page-2');

    // 第二次相同条件带 If-None-Match 命中 304，直接返回缓存结果
    final page1Cached = await repo.listCatalog();
    expect(seenIfNoneMatch[1], '"etag-p1"');
    expect(page1Cached.items.single.name, '第一页主题');

    final page2 = await repo.listCatalog(cursor: page1.nextCursor);
    expect(page2.items.single.name, '第二页主题');
    expect(page2.nextCursor, isNull);

    final updates = await repo.checkUpdates([id]);
    expect(updates[id]?.version, 2);
    expect(hitCount, 4);
  });

  test('下载器：严格请求目录 packageUrl，SHA-256 不一致与中途取消均立即清理 .part', () async {
    final requestedUrls = <String>[];
    final streamCtrl = StreamController<Uint8List>();
    var mode = 'bad_sha';

    final dio = Dio(BaseOptions(baseUrl: 'https://fixture.test/api'));
    dio.httpClientAdapter = _StreamStubAdapter((options) async {
      requestedUrls.add(options.uri.toString());
      if (mode == 'cancel_stream') {
        return ResponseBody(
          streamCtrl.stream,
          200,
          headers: {
            Headers.contentLengthHeader: ['${sharedPackBytes.length}'],
          },
        );
      }
      return ResponseBody.fromBytes(
        sharedPackBytes,
        200,
        headers: {
          Headers.contentLengthHeader: ['${sharedPackBytes.length}'],
        },
      );
    });

    final repo = ThemeStoreRepository(dio);
    final downloader = ThemePackDownloadManager(store: store, repository: repo);
    const familyId = '11111111-2222-4333-8444-555555555555';
    final partFile = File(
      p.join(temp.path, 'themes', 'downloads', '$familyId-v1.part'),
    );

    // 1. SHA-256 故意不一致 -> 抛错且 .part 已被删除，且请求 URL 等于目录给出的自定义路径
    final badItem = _fakeCatalogItem(
      familyId: familyId,
      packageUrl: '/custom-cdn/exact-pack-v1.sltheme',
      packageSize: sharedPackBytes.length,
      packageSha256: '0' * 64,
    );
    await expectLater(
      downloader.downloadAndInstall(
        item: badItem,
        provider: themeProvider,
        appVersion: '1.7.12',
      ),
      throwsA(isA<ThemePackError>()),
    );
    expect(
      requestedUrls.single,
      'https://fixture.test/custom-cdn/exact-pack-v1.sltheme',
    );
    expect(await partFile.exists(), isFalse);

    // 2. 流式下载中途取消 -> 立即删除已写入的半截 .part
    mode = 'cancel_stream';
    final goodItem = _fakeCatalogItem(
      familyId: familyId,
      packageUrl: '/custom-cdn/exact-pack-v1.sltheme',
      packageSize: sharedPackBytes.length,
      packageSha256: sharedPackSha256,
    );
    final future = downloader.downloadAndInstall(
      item: goodItem,
      provider: themeProvider,
      appVersion: '1.7.12',
    );
    streamCtrl.add(Uint8List.sublistView(sharedPackBytes, 0, 512));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(downloader.activeTaskForFamily(familyId), isNotNull);

    final canceled = expectLater(future, throwsA(isA<DioException>()));
    await downloader.cancel(familyId, 1);
    await canceled;
    expect(await partFile.exists(), isFalse);
    await streamCtrl.close();
  });

  testWidgets('商城列表状态、详情六态按钮与跨页面全局试用横条', (tester) async {
    const familyId = '11111111-2222-4333-8444-555555555555';
    var storeState = 'disabled'; // disabled -> error -> empty -> loaded
    var serverVersion = 1;
    var minAppVer = '1.0.0';
    Completer<void>? holdDownload;

    final dio = Dio(BaseOptions(baseUrl: 'https://fixture.test/api'));
    dio.httpClientAdapter = _StreamStubAdapter((options) async {
      final path = options.uri.path;
      final hold = holdDownload;
      if (path == '/custom-cdn/exact-pack-v1.sltheme' ||
          path == '/custom-cdn/exact-pack-v2.sltheme') {
        if (hold != null) {
          await hold.future;
        }
        final bytes = path.endsWith('v2.sltheme')
            ? await _buildValidPackBytes(id: familyId, version: 2, name: '海盐蓝')
            : sharedPackBytes;
        return ResponseBody.fromBytes(bytes, 200);
      }
      if (storeState == 'disabled') {
        return ResponseBody.fromString(
          jsonEncode({
            'code': 'theme_store_disabled',
            'error': '主题商城暂未开放',
          }),
          503,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      }
      if (storeState == 'error') {
        return ResponseBody.fromString('bad gateway', 502);
      }
      if (storeState == 'empty') {
        return ResponseBody.fromString(
          jsonEncode({'items': []}),
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      }
      if (path.endsWith('/themes/deadbeef-2222-4333-8444-555555555555')) {
        return ResponseBody.fromString(
          jsonEncode({'code': 'theme_not_found', 'error': '不存在'}),
          404,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      }
      final v2Bytes = serverVersion == 2
          ? await _buildValidPackBytes(id: familyId, version: 2, name: '海盐蓝')
          : sharedPackBytes;
      final itemJson = {
        'familyId': familyId,
        'version': serverVersion,
        'name': '海盐蓝',
        'description': '清爽海盐配色',
        'license': 'CC-BY-4.0',
        'author': {'id': 1, 'nickname': '海盐作者', 'avatarUrl': ''},
        'tags': ['清新'],
        'source': 'official',
        'previewLight': '',
        'previewDark': '',
        'packageUrl': '/custom-cdn/exact-pack-v$serverVersion.sltheme',
        'packageSize': v2Bytes.length,
        'packageSha256': sha256.convert(v2Bytes).toString(),
        'minAppVersion': minAppVer,
        'downloads': 88,
        'updatedAt': '2026-11-18T00:00:00Z',
      };
      if (path.endsWith('/themes/$familyId')) {
        return ResponseBody.fromString(
          jsonEncode(itemJson),
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      }
      return ResponseBody.fromString(
        jsonEncode({
          'items': [itemJson]
        }),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    });

    final auth = _TestAuth(dio);
    final repo = ThemeStoreRepository(dio);
    final downloader = ThemePackDownloadManager(store: store, repository: repo);
    final catalogBoundary = GlobalKey();

    await tester.pumpWidget(
      _wrapWithProviders(
        auth: auth,
        themeProvider: themeProvider,
        home: RepaintBoundary(
          key: catalogBoundary,
          child: ThemeStoreScreen(
            repository: repo,
            downloadManager: downloader,
            appVersion: '1.7.12',
          ),
        ),
      ),
    );
    await _settleIo(tester);
    expect(find.text('主题商城暂未开放'), findsOneWidget);

    storeState = 'error';
    await tester.tap(find.text('重试'));
    await _settleIo(tester);
    expect(find.textContaining('加载主题商城失败'), findsOneWidget);

    storeState = 'empty';
    await tester.tap(find.text('重试'));
    await _settleIo(tester);
    expect(find.textContaining('暂无符合条件的主题'), findsOneWidget);

    storeState = 'loaded';
    await tester.tap(find.text('热门'));
    await _settleIo(tester);
    expect(find.text('官方主题'), findsOneWidget);
    expect(find.text('海盐蓝'), findsWidgets);
    final qaDirectory = Platform.environment['THEME_WORKSHOP_QA_DIR'];
    if (qaDirectory != null) {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      try {
        await tester.pumpAndSettle();
        final boundary = catalogBoundary.currentContext!.findRenderObject()
            as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          image.dispose();
          final directory = await Directory(qaDirectory).create(recursive: true);
          await File(p.join(directory.path, 'theme-store.png'))
              .writeAsBytes(bytes!.buffer.asUint8List());
        });
      } finally {
        await tester.binding.setSurfaceSize(null);
        await tester.pumpAndSettle();
      }
    }

    // 进入详情页：状态 1 未安装
    await tester.tap(find.text('海盐蓝').first);
    await _settleIo(tester);
    expect(find.text('下载并应用'), findsOneWidget);

    // 状态 2（下载中 + 取消）：阻塞流并在进行中点击取消，恢复未安装状态
    holdDownload = Completer<void>();
    await tester.tap(find.text('下载并应用'));
    for (var i = 0;
        i < 30 &&
            find
                .byKey(const ValueKey('theme-detail-cancel-download'))
                .evaluate()
                .isEmpty;
        i++) {
      await _settleIo(tester, cycles: 2);
    }
    expect(
      find.byKey(const ValueKey('theme-detail-cancel-download')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('theme-detail-cancel-download')),
    );
    holdDownload.complete();
    holdDownload = null;
    await _settleIo(tester);
    expect(find.text('下载并应用'), findsOneWidget);

    // 跨页全局试用：点击试用（先下载安装再进入试用） -> 返回商城列表 -> 顶部试用条保持可见 -> 结束恢复原外观
    final originalPrimary =
        themeProvider.buildAppTheme(Brightness.light).colorScheme.primary;
    await tester.tap(find.byKey(const ValueKey('theme-detail-trial-button')));
    for (var i = 0; i < 40 && !themeProvider.isInTrial; i++) {
      await _settleIo(tester, cycles: 2);
    }
    expect(themeProvider.isInTrial, isTrue);
    expect(find.byKey(const ValueKey('theme-trial-banner')), findsOneWidget);

    await tester.pageBack();
    await _settleIo(tester);
    expect(find.text('主题商城'), findsOneWidget);
    expect(find.byKey(const ValueKey('theme-trial-banner')), findsOneWidget);

    await tester.runAsync(() async {
      await themeProvider.endTrial();
    });
    ScaffoldMessenger.of(
      tester.element(find.byType(Scaffold).first),
    ).clearSnackBars();
    await _settleIo(tester);
    expect(themeProvider.isInTrial, isFalse);
    expect(find.byKey(const ValueKey('theme-trial-banner')), findsNothing);
    expect(
      themeProvider.buildAppTheme(Brightness.light).colorScheme.primary,
      originalPrimary,
    );

    // 重新进入详情：v1 已在试用时安装但未正式应用 -> 状态 3（已安装未应用 -> 应用）
    await tester.tap(find.text('海盐蓝').first);
    await _waitKey(tester, const ValueKey('theme-detail-state-apply'));
    expect(
      find.byKey(const ValueKey('theme-detail-state-apply')),
      findsOneWidget,
    );

    // 点击应用 -> 状态 4（正在使用 / 已应用）
    ScaffoldMessenger.of(
      tester.element(find.byType(Scaffold).last),
    ).clearSnackBars();
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('theme-detail-state-apply')));
    await _waitKey(tester, const ValueKey('theme-detail-state-active'));
    expect(
      find.byKey(const ValueKey('theme-detail-state-active')),
      findsOneWidget,
    );

    // 服务端升到 v2 -> 状态 5（有新版本 -> 更新）
    serverVersion = 2;
    await tester.pageBack();
    await _settleIo(tester);
    await tester.tap(find.text('海盐蓝').first);
    await _waitKey(tester, const ValueKey('theme-detail-state-update'));
    expect(
      find.byKey(const ValueKey('theme-detail-state-update')),
      findsOneWidget,
    );

    // 服务端要求最低版本 99.0.0 -> 状态 6（需要更新 App）
    minAppVer = '99.0.0';
    await tester.pageBack();
    await _settleIo(tester);
    await tester.tap(find.text('海盐蓝').first);
    await _waitKey(tester, const ValueKey('theme-detail-state-too-old'));
    expect(
      find.byKey(const ValueKey('theme-detail-state-too-old')),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('投稿幂等键与双击防护、我的投稿切号会话隔离、审核拒绝原因必选', (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final submittedKeys = <String>[];
    var failSubmit = true;
    Completer<List<ThemeSubmissionItem>>? slowListUser1;

    final dio = Dio(BaseOptions(baseUrl: 'https://fixture.test/api'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          if (options.path == '/themes/submissions' &&
              options.method == 'POST') {
            submittedKeys.add(options.headers['Idempotency-Key'] as String);
            await Future<void>.delayed(const Duration(milliseconds: 60));
            if (failSubmit) {
              handler.reject(
                DioException(
                  requestOptions: options,
                  response: Response(
                    requestOptions: options,
                    statusCode: 503,
                    data: {'error': '网络抖动'},
                  ),
                ),
              );
              return;
            }
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: {
                  'id': 'sub-1',
                  'familyId': sharedPackManifest.id,
                  'version': 1,
                  'name': '海盐蓝',
                  'status': 'pending',
                },
              ),
            );
            return;
          }
          if (options.path == '/themes/submissions' &&
              options.method == 'GET') {
            final slow = slowListUser1;
            if (slow != null) {
              final list = await slow.future;
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: {
                    'items': [
                      for (final it in list)
                        {
                          'id': it.id,
                          'familyId': it.familyId,
                          'version': it.version,
                          'name': it.name,
                          'status': it.status,
                        },
                    ],
                  },
                ),
              );
              return;
            }
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: {'items': []},
              ),
            );
            return;
          }
          handler.resolve(
            Response(requestOptions: options, statusCode: 200, data: {}),
          );
        },
      ),
    );

    final auth = _TestAuth(dio, id: 1, role: 'user');
    final repo = ThemeStoreRepository(dio);

    // 1. 投稿页：未勾选使用权不可点；双击只发一次；失败后原表单重试复用同一幂等键，改名后换新键
    await tester.pumpWidget(
      _wrapWithProviders(
        auth: auth,
        themeProvider: themeProvider,
        home: ThemeSubmissionScreen(
          initialPackageBytes: sharedPackBytes,
          initialManifest: sharedPackManifest,
          repository: repo,
          appVersion: '1.7.12',
        ),
      ),
    );
    await tester.pumpAndSettle();

    final submitFinder = find.byKey(const ValueKey('theme-submit-button'));
    await tester.ensureVisible(submitFinder);
    expect(tester.widget<FilledButton>(submitFinder).onPressed, isNull);

    final rightsFinder =
        find.byKey(const ValueKey('theme-submit-rights-checkbox'));
    await tester.ensureVisible(rightsFinder);
    await tester.tap(rightsFinder);
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(submitFinder).onPressed, isNotNull);

    // 连续快速点击两次，只发 1 个请求
    await tester.ensureVisible(submitFinder);
    await tester.tap(submitFinder);
    await tester.pump(const Duration(milliseconds: 10));
    await tester.tap(submitFinder, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(submittedKeys.length, 1);

    // 不改表单直接重试 -> 复用完全相同的幂等键
    await tester.tap(submitFinder);
    await tester.pumpAndSettle();
    expect(submittedKeys.length, 2);
    expect(submittedKeys[1], submittedKeys[0]);

    // 修改名称后再提交 -> 生成新幂等键
    failSubmit = false;
    final nameField = find.byKey(const ValueKey('theme-submit-name'));
    await tester.ensureVisible(nameField);
    await tester.enterText(nameField, '海盐蓝修订版');
    await tester.pumpAndSettle();
    await tester.ensureVisible(submitFinder);
    await tester.tap(submitFinder);
    await tester.pumpAndSettle();
    expect(submittedKeys.length, 3);
    expect(submittedKeys[2], isNot(submittedKeys[0]));

    // 2. 我的投稿：账号 1 请求飞行中切换到账号 2 -> 迟到结果不写入列表
    slowListUser1 = Completer<List<ThemeSubmissionItem>>();
    await tester.pumpWidget(
      _wrapWithProviders(
        auth: auth,
        themeProvider: themeProvider,
        home: MyThemeSubmissionsScreen(repository: repo),
      ),
    );
    await tester.pump();
    final pendingForUser1 = slowListUser1;
    slowListUser1 = null;
    auth.switchUser(id: 2, role: 'user');
    await tester.pumpAndSettle();

    pendingForUser1.complete([
      const ThemeSubmissionItem(
        id: 'stale-u1',
        familyId: '11111111-2222-4333-8444-555555555555',
        version: 1,
        authorUserId: 1,
        name: '旧账号残留主题',
        description: '',
        tags: [],
        license: 'CC-BY-4.0',
        source: 'community',
        status: 'pending',
        minAppVersion: '1.0.0',
        fontCopyright: '',
        fontLicenseNote: '',
        packageSha256: '',
        packageSize: 100,
        packageUrl: '',
        previewLight: '',
        previewDark: '',
        reviewReasonCode: '',
        reviewNote: '',
        reasonMessage: '',
        createdAt: '',
        updatedAt: '',
      ),
    ]);
    await tester.pumpAndSettle();
    expect(find.textContaining('旧账号残留主题'), findsNothing);

    // 3. 管理员拒绝弹窗：未选原因前确认按钮置灰，选中原因后允许提交
    auth.switchUser(id: 3, role: 'admin');
    const subItem = ThemeSubmissionItem(
      id: 'sub-admin-1',
      familyId: '11111111-2222-4333-8444-555555555555',
      version: 1,
      authorUserId: 1,
      name: '待审海盐蓝',
      description: '简介',
      tags: ['清新'],
      license: 'CC-BY-4.0',
      source: 'community',
      status: 'pending',
      minAppVersion: '1.0.0',
      fontCopyright: '',
      fontLicenseNote: '',
      packageSha256: '',
      packageSize: 1024,
      packageUrl: '',
      previewLight: '',
      previewDark: '',
      reviewReasonCode: '',
      reviewNote: '',
      reasonMessage: '',
      createdAt: '',
      updatedAt: '',
    );
    await tester.pumpWidget(
      _wrapWithProviders(
        auth: auth,
        themeProvider: themeProvider,
        home: AdminThemeReviewDetailScreen(
          submission: subItem,
          repository: repo,
          appVersion: '1.7.12',
        ),
      ),
    );
    await tester.pumpAndSettle();
    final rejectBtn = find.byKey(const ValueKey('admin-theme-reject-button'));
    await tester.ensureVisible(rejectBtn);
    await tester.tap(rejectBtn);
    await tester.pumpAndSettle();

    final confirmBtn = find.byKey(const ValueKey('admin-theme-confirm-reject'));
    expect(tester.widget<FilledButton>(confirmBtn).onPressed, isNull);

    await tester.tap(find.byKey(const ValueKey('theme-reason-contrast')));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(confirmBtn).onPressed, isNotNull);
    await tester.tap(confirmBtn);
    await _settleIo(tester);
  });

  testWidgets('本机回环 Go 服务端端到端七步闭环（含沉浸页头、贴纸、私有包试用、版本更新与下架深链）',
      (tester) async {
    HttpOverrides.global = null;
    _GoLoopbackServer? server;
    try {
      late String familyId;
      await tester.runAsync(() async {
        server = await _GoLoopbackServer.start();
        final repoA = ThemeStoreRepository(server!.clientFor('user1'));
        final repoAdmin = ThemeStoreRepository(server!.clientFor('admin1'));
        final repoC = ThemeStoreRepository(server!.clientFor('user2'));
        const scopeA =
            PublishSessionScope(accountId: 1, accountSessionEpoch: 1);
        const scopeAdmin =
            PublishSessionScope(accountId: 3, accountSessionEpoch: 1);

        final storeAdmin = ThemePackStore(
          directory: Directory(p.join(temp.path, 'themes-admin')),
        );
        final providerAdmin =
            ThemeProvider(loadOnStart: false, themePackStore: storeAdmin);
        await providerAdmin.loadThemeForTesting();
        final dlAdmin =
            ThemePackDownloadManager(store: storeAdmin, repository: repoAdmin);
        final dlC = ThemePackDownloadManager(store: store, repository: repoC);

        // 步骤 1：用户 A 从工坊导出含沉浸页头、卡片样式、调色与透明贴纸的主题并投稿
        final v1Pack = await _buildValidPackBytes(
          name: '海盐蓝环回V1',
          immersiveAndDecorated: true,
        );
        final sub1 = await repoA.submit(
          packageBytes: v1Pack,
          idempotencyKey: 'e2e-userA-sub-0001',
          session: scopeA,
          name: '海盐蓝环回',
          description: '首次投稿验证',
          tags: const ['清新', '明暗自适应'],
          license: 'CC-BY-4.0',
        );
        expect(sub1.status, 'pending');
        expect(sub1.version, 1);

        // 步骤 2：管理员 B 下载私有待审包开启全局试用 -> 验证布局与贴纸生效 -> 结束试用无残留 -> 选择原因拒绝
        final pendingList =
            await repoAdmin.adminList(session: scopeAdmin, status: 'pending');
        final pendingSub1 =
            pendingList.firstWhere((item) => item.id == sub1.id);
        final privatePack = await dlAdmin.downloadPrivatePack(
          submission: pendingSub1,
          appVersion: '1.7.12',
          session: scopeAdmin,
        );
        await providerAdmin.startTrial(
          groups: ThemeGroup.applicable,
          pack: privatePack,
        );
        expect(providerAdmin.isInTrial, isTrue);
        expect(
          providerAdmin.appearance.group(ThemeGroup.layout)?['value']?['home']
              ?['preset'],
          'immersive',
        );
        expect(
          (providerAdmin.appearance.group(ThemeGroup.decoration)?['light']
                  ?['home']?['stickers'] as List?)
              ?.length,
          2,
        );
        await providerAdmin.endTrial();
        expect(providerAdmin.isInTrial, isFalse);
        expect(providerAdmin.appearance.group(ThemeGroup.layout), isNull);
        expect(providerAdmin.appearance.group(ThemeGroup.decoration), isNull);

        final rejected = await repoAdmin.adminReview(
          sub1.id,
          approve: false,
          reasonCode: 'contrast',
          note: '标签对比请再确认',
          session: scopeAdmin,
        );
        expect(rejected.status, 'rejected');

        // 步骤 3：用户 A 在“我的投稿”看到未通过原因并重新提交，步骤 4：管理员 B 审核通过
        final mySubsAfterReject =
            await repoA.listMySubmissions(session: scopeA);
        final rejectedSeen =
            mySubsAfterReject.firstWhere((e) => e.id == sub1.id);
        expect(rejectedSeen.status, 'rejected');
        expect(rejectedSeen.reviewReasonCode, 'contrast');
        expect(rejectedSeen.reasonMessage, contains('对比度'));

        final subRe = await repoA.submit(
          packageBytes: v1Pack,
          idempotencyKey: 'e2e-userA-resub-0002',
          session: scopeA,
          name: '海盐蓝环回',
          description: '修正后重新投稿',
          tags: const ['清新', '明暗自适应'],
          license: 'CC-BY-4.0',
        );
        familyId = subRe.familyId;
        final approvedV1 = await repoAdmin.adminReview(
          subRe.id,
          approve: true,
          session: scopeAdmin,
        );
        expect(approvedV1.status, 'approved');

        // 步骤 5：客户端 C 从“最新”下载并应用，验证规范化后的页头布局、卡片描边/阴影、调色与贴纸顺序/透明度，且作者作品列表可见
        final latestPage = await repoC.listCatalog(sort: 'latest');
        final catalogV1 =
            latestPage.items.firstWhere((e) => e.familyId == familyId);
        expect(catalogV1.version, 1);

        final installedV1 = await dlC.downloadAndInstall(
          item: catalogV1,
          provider: themeProvider,
          appVersion: '1.7.12',
        );
        await themeProvider.applyInstalledTheme(
          installedV1,
          ThemeGroup.applicable,
        );
        expect(themeProvider.isThemeVersionActive(familyId, 1), isTrue);
        expect(
          themeProvider.appearance.group(ThemeGroup.layout)?['value']?['home']
              ?['preset'],
          'immersive',
        );
        final appliedCardStyle = themeProvider.appearance
            .group(ThemeGroup.material)?['light']?['cardStyle'] as Map?;
        expect(appliedCardStyle?['borderWidth'], 1.5);
        expect(appliedCardStyle?['shadow'], 'soft');
        final appliedStickers = (themeProvider.appearance
                .group(ThemeGroup.decoration)?['light']?['home']?['stickers']
            as List);
        expect(appliedStickers.length, 2);
        expect((appliedStickers[0] as Map)['x'], 0.82);
        expect((appliedStickers[0] as Map)['rotation'], 12.0);
        expect((appliedStickers[1] as Map)['x'], 0.14);
        expect((appliedStickers[1] as Map)['rotation'], -8.0);

        final authorWorks = await repoC.listUserThemes(1);
        expect(authorWorks.any((w) => w.familyId == familyId), isTrue);

        // 步骤 6：用户 A 提交同族新版本 v2，管理员通过后客户端 C 检出“可更新”，更新到 v2 并应用
        final v2Pack = await _buildValidPackBytes(
          id: familyId,
          version: 2,
          name: '海盐蓝环回',
          seedHex: '#1D6FD1',
          immersiveAndDecorated: true,
        );
        final subV2 = await repoA.submit(
          packageBytes: v2Pack,
          idempotencyKey: 'e2e-userA-v2-0003',
          familyId: familyId,
          session: scopeA,
          name: '海盐蓝环回',
          description: 'v2 升级配色',
          tags: const ['清新', '明暗自适应'],
          license: 'CC-BY-4.0',
        );
        expect(subV2.version, 2);
        await repoAdmin.adminReview(
          subV2.id,
          approve: true,
          session: scopeAdmin,
        );

        final updateMap = await repoC.checkUpdates([familyId]);
        expect(updateMap[familyId]?.version, 2);

        final installedV2 = await dlC.downloadAndInstall(
          item: updateMap[familyId]!,
          provider: themeProvider,
          appVersion: '1.7.12',
        );
        await themeProvider.applyInstalledTheme(
          installedV2,
          ThemeGroup.applicable,
        );
        expect(themeProvider.isThemeVersionActive(familyId, 2), isTrue);

        // 步骤 7：管理员下架该主题 -> 客户端 C 已安装副本继续可用，商城列表不再返回
        await repoAdmin.adminRemove(
          familyId,
          reasonCode: 'copyright',
          note: '下架回归验证',
          session: scopeAdmin,
        );
        final localThemes = await themeProvider.installedThemes();
        expect(
          localThemes.any((t) => t.familyId == familyId && t.manifest.version == 2),
          isTrue,
        );
        final afterRemoveCatalog = await repoC.listCatalog(sort: 'latest');
        expect(
          afterRemoveCatalog.items.any((e) => e.familyId == familyId),
          isFalse,
        );

        providerAdmin.dispose();
      });

      // 通过分享链接解析出的 familyId 打开详情页，真实请求回环服务端 404 后显示“主题不存在或已下架”
      final shareUrl = ThemeShareLink.buildWebUrl(familyId);
      final parsedId = ThemeShareLink.parseFamilyId(shareUrl)!;
      final dioC = server!.clientFor('user2');
      final authC = _TestAuth(dioC, id: 2, role: 'user');
      final repoC = ThemeStoreRepository(dioC);

      await tester.pumpWidget(
        _wrapWithProviders(
          auth: authC,
          themeProvider: themeProvider,
          home: ThemeDetailScreen(
            familyId: parsedId,
            repository: repoC,
            appVersion: '1.7.12',
          ),
        ),
      );
      await _settleIo(tester, cycles: 15);
      expect(find.text('主题不存在或已下架'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    } finally {
      await tester.runAsync(() async {
        await server?.stop();
      });
    }
  });

  testWidgets('本机主题页：存在远端新版本时显示可更新徽标', (tester) async {
    const familyId = '11111111-2222-4333-8444-555555555555';
    await tester.runAsync(() async {
      final prepared = await ThemePackCodec.decodeStorePackage(
        sharedPackBytes,
        appVersion: '1.7.12',
      );
      final installed = await themeProvider.installStoreTheme(
        prepared,
        source: 'community',
        familyId: familyId,
      );
      final tiny = img.Image(width: 2, height: 2);
      img.fill(tiny, color: img.ColorRgb8(47, 127, 216));
      final codec =
          await ui.instantiateImageCodec(Uint8List.fromList(img.encodePng(tiny)));
      final frame = await codec.getNextFrame();
      codec.dispose();
      PaintingBinding.instance.imageCache.putIfAbsent(
        FileImage(
          File(
            '${installed.directory}/${installed.manifest.data['preview']['light']}',
          ),
        ),
        () => OneFrameImageStreamCompleter(
          Future.value(ImageInfo(image: frame.image)),
        ),
      );
    });

    final dio = Dio(BaseOptions(baseUrl: 'https://fixture.test/api'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: {
                'items': [
                  {
                    'familyId': familyId,
                    'version': 3,
                    'name': '海盐蓝',
                    'packageUrl': '/api/themes/$familyId/versions/3/package',
                    'packageSize': sharedPackBytes.length,
                    'packageSha256': sharedPackSha256,
                    'minAppVersion': '1.0.0',
                  }
                ],
              },
            ),
          );
        },
      ),
    );
    final auth = _TestAuth(dio);
    final repo = ThemeStoreRepository(dio);

    await tester.pumpWidget(
      _wrapWithProviders(
        auth: auth,
        themeProvider: themeProvider,
        home: InstalledThemesScreen(repository: repo),
      ),
    );
    for (var i = 0; i < 40; i++) {
      await _settleIo(tester, cycles: 2);
      if (find.text('可更新 v3').evaluate().isNotEmpty) break;
    }
    expect(find.text('可更新 v3'), findsOneWidget);
    expect(find.text('前往更新'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await _settleIo(tester, cycles: 4);
    PaintingBinding.instance.imageCache.clear();
  });
}

class _BetaAssetBundle extends CachingAssetBundle {
  _BetaAssetBundle(this.loadTheme);

  final Future<ByteData> Function() loadTheme;

  @override
  Future<ByteData> load(String key) =>
      key == ThemeBetaNotice.assetPath ? loadTheme() : rootBundle.load(key);
}

class _StreamStubAdapter implements HttpClientAdapter {
  _StreamStubAdapter(this._handler);
  final Future<ResponseBody> Function(RequestOptions options) _handler;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (cancelFuture != null) {
      return Future.any([
        _handler(options),
        cancelFuture.then((_) {
          throw DioException.requestCancelled(
            requestOptions: options,
            reason: 'cancelled',
          );
        }),
      ]);
    }
    return _handler(options);
  }

  @override
  void close({bool force = false}) {}
}
