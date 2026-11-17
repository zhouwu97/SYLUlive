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
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:shenliyuan/features/theme_pack/admin_theme_review_screen.dart';
import 'package:shenliyuan/features/theme_pack/installed_themes_screen.dart';
import 'package:shenliyuan/features/theme_pack/theme_appearance.dart';
import 'package:shenliyuan/features/theme_pack/theme_contrast.dart';
import 'package:shenliyuan/features/theme_pack/theme_manifest.dart';
import 'package:shenliyuan/features/theme_pack/theme_pack_codec.dart';
import 'package:shenliyuan/features/theme_pack/theme_pack_store.dart';
import 'package:shenliyuan/features/theme_pack/theme_resolver.dart';
import 'package:shenliyuan/features/theme_pack/theme_store_repository.dart';
import 'package:shenliyuan/features/theme_pack/theme_store_screen.dart';
import 'package:shenliyuan/features/theme_pack/theme_submission_screen.dart';
import 'package:shenliyuan/features/theme_pack/theme_trial_banner.dart';
import 'package:shenliyuan/features/theme_pack/theme_workshop_samples.dart';
import 'package:shenliyuan/features/theme_pack/theme_workshop_screen.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/services/publish_session_scope.dart';
import 'package:shenliyuan/theme/app_palette.dart';

import '../helpers/emoji_flow_qa.dart' show settleEmojiQAImages;
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
    await (FontLoader('Roboto')
          ..addFont(rootBundle.load('assets/fonts/NotoSansCJKsc-Regular.otf')))
        .load();
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

    await downloader.cancel(familyId, 1);
    await expectLater(future, throwsA(isA<DioException>()));
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

    await tester.pumpWidget(
      _wrapWithProviders(
        auth: auth,
        themeProvider: themeProvider,
        home: ThemeStoreScreen(
          repository: repo,
          downloadManager: downloader,
          appVersion: '1.7.12',
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

  testWidgets('P5 首批五套官方主题：工坊对比度全绿、双管理员隔离上架与官方区顺序核验',
      (tester) async {
    HttpOverrides.global = null;
    _GoLoopbackServer? server;
    Directory? artDir;
    try {
      final exportReport =
          Platform.environment['EXPORT_OFFICIAL_THEMES_REPORT'] == '1';
      late List<_OfficialThemeSpec> specs;
      final normalizedPacks = <String, PreparedThemePack>{};
      final catalogRecords = <String, ThemeCatalogItem>{};

      await tester.runAsync(() async {
        artDir = await Directory.systemTemp.createTemp('sltheme-p5-art-');
        specs = await _buildFiveOfficialThemes(artDir!);
        for (final spec in specs) {
          expect(
            spec.state.checkAllContrast(),
            isEmpty,
            reason: '${spec.state.name} 工坊对比度必须全绿',
          );
          final decoded =
              await ThemePackCodec.decode(spec.bytes, appVersion: '1.7.12');
          expect(
            ThemeContrast.check(decoded.manifest),
            isEmpty,
            reason: '${spec.state.name} manifest 对比度必须全绿',
          );
        }

        server = await _GoLoopbackServer.start();
        final repoAdmin1 = ThemeStoreRepository(server!.clientFor('admin1'));
        final repoAdmin2 = ThemeStoreRepository(server!.clientFor('admin2'));
        final repoPublic = ThemeStoreRepository(server!.clientFor('user1'));
        const scopeAdmin1 =
            PublishSessionScope(accountId: 3, accountSessionEpoch: 1);
        const scopeAdmin2 =
            PublishSessionScope(accountId: 4, accountSessionEpoch: 1);

        for (var i = 0; i < specs.length; i++) {
          final spec = specs[i];
          final submitted = await repoAdmin1.submit(
            packageBytes: spec.bytes,
            idempotencyKey: 'p5-official-sub-${i + 1}-${spec.slug}',
            session: scopeAdmin1,
            source: 'official',
            name: spec.state.name,
            description: spec.state.description,
            tags: spec.state.tags,
            license: spec.state.license,
          );
          expect(submitted.source, 'official');
          expect(submitted.status, 'pending');

          if (i == 0) {
            // 管理员本人不得自审
            await expectLater(
              repoAdmin1.adminReview(
                submitted.id,
                approve: true,
                session: scopeAdmin1,
              ),
              throwsA(
                isA<ThemeStoreApiException>()
                    .having((e) => e.code, 'code', 'theme_forbidden'),
              ),
            );
          }

          final approved = await repoAdmin2.adminReview(
            submitted.id,
            approve: true,
            session: scopeAdmin2,
          );
          expect(approved.status, 'approved');
          expect(approved.source, 'official');
          await Future<void>.delayed(const Duration(milliseconds: 15));
        }

        final officialPage = await repoPublic.listCatalog(sort: 'official');
        expect(
          officialPage.items.map((e) => e.name).toList(),
          ['沈理青', '墨夜', '海盐蓝', '樱粉', '纸感'],
        );
        for (final item in officialPage.items) {
          expect(item.isOfficial, isTrue);
        }

        if (exportReport) {
          final p5ArtifactDir = Directory(
            p.normalize(
              p.join(Directory.current.path, '..', 'artifacts', 'theme-p5', 'packages'),
            ),
          );
          await p5ArtifactDir.create(recursive: true);

          for (var i = 0; i < officialPage.items.length; i++) {
            final item = officialPage.items[i];
            final slug = specs[i].slug;
            catalogRecords[slug] = item;
            final resp = await repoPublic.dio.getUri<List<int>>(
              Uri.parse(repoPublic.resolveUrl(item.packageUrl)),
              options: Options(responseType: ResponseType.bytes),
            );
            final normBytes = Uint8List.fromList(resp.data!);
            expect(
              sha256.convert(normBytes).toString(),
              item.packageSha256,
            );
            await File(p.join(p5ArtifactDir.path, '$slug.sltheme'))
                .writeAsBytes(normBytes, flush: true);
            normalizedPacks[slug] = await ThemePackCodec.decodeStorePackage(
              normBytes,
              appVersion: '1.7.12',
            );
          }
        }
      });

      // 挂载商城页面验证“官方主题”横向架显示首批五套
      final dioUser = server!.clientFor('user1');
      final authUser = _TestAuth(dioUser, id: 1, role: 'user');
      final repoUser = ThemeStoreRepository(dioUser);
      await tester.pumpWidget(
        _wrapWithProviders(
          auth: authUser,
          themeProvider: themeProvider,
          home: ThemeStoreScreen(repository: repoUser, appVersion: '1.7.12'),
        ),
      );
      await _settleIo(tester, cycles: 10);
      expect(find.text('官方主题'), findsOneWidget);
      expect(find.text('沈理青'), findsWidgets);
      expect(find.text('墨夜'), findsWidgets);

      if (exportReport) {
        await _exportOfficialThemesReportAndScreenshots(
          tester: tester,
          specs: specs,
          normalizedPacks: normalizedPacks,
          catalogRecords: catalogRecords,
        );
      }
      await tester.pumpWidget(const SizedBox.shrink());
    } finally {
      await tester.runAsync(() async {
        await server?.stop();
        if (artDir != null && await artDir!.exists()) {
          await artDir!.delete(recursive: true);
        }
      });
    }
  });
}

class _OfficialThemeSpec {
  const _OfficialThemeSpec({
    required this.slug,
    required this.state,
    required this.bytes,
    required this.designSummary,
    required this.assetNote,
    this.defaultDeltas = const [],
  });

  final String slug;
  final ThemeWorkshopStateData state;
  final Uint8List bytes;
  final String designSummary;
  final String assetNote;
  final List<String> defaultDeltas;
}

Future<List<_OfficialThemeSpec>> _buildFiveOfficialThemes(
  Directory artDir,
) async {
  WorkshopVariantDraft buildSeededVariant({
    required String seedHex,
    required String schemeVariant,
    required Brightness brightness,
    Map<String, String> overrides = const {},
    List<String>? customCourses,
  }) {
    final seed = ThemeContrast.parseColor(seedHex);
    final variantEnum = ThemeResolver.parseSchemeVariant(schemeVariant);
    final baseTokens = ThemeResolver.deriveTokens(
      seedColor: seed,
      brightness: brightness,
      schemeVariant: variantEnum,
      overrides: overrides,
    );
    final courses = customCourses ??
        ThemeResolver.generateCoursePalette(
          seedColor: seed,
          brightness: brightness,
          background: ThemeContrast.parseColor(baseTokens['background']!),
          courseCardText:
              ThemeContrast.parseColor(baseTokens['courseCardText']!),
        );
    final fixed = ThemeResolver.autoFixVariant(
      brightness: brightness,
      tokens: baseTokens,
      coursePalette: courses,
    );
    return WorkshopVariantDraft(
      seedColor: seedHex.toUpperCase(),
      schemeVariant: schemeVariant,
      overrides: {
        ...overrides.map((k, v) => MapEntry(k, v.toUpperCase())),
        ...fixed.changedOverrides,
      },
      coursePalette: fixed.coursePalette,
    );
  }

  // 生成两套原创几何渐变页头背景与透明几何贴纸（CC0-1.0，项目自制，不含任何文字/水印/第三方素材）
  Future<String> writeGradientBg(
    String fileName,
    (int, int, int) topRgb,
    (int, int, int) bottomRgb,
    (int, int, int) accentRgb,
  ) async {
    final canvas = img.Image(width: 720, height: 320);
    for (var y = 0; y < canvas.height; y++) {
      final t = y / (canvas.height - 1);
      final r = (topRgb.$1 + (bottomRgb.$1 - topRgb.$1) * t).round();
      final g = (topRgb.$2 + (bottomRgb.$2 - topRgb.$2) * t).round();
      final b = (topRgb.$3 + (bottomRgb.$3 - topRgb.$3) * t).round();
      for (var x = 0; x < canvas.width; x++) {
        canvas.setPixelRgb(x, y, r, g, b);
      }
    }
    img.fillCircle(
      canvas,
      x: 590,
      y: 78,
      radius: 110,
      color: img.ColorRgba8(accentRgb.$1, accentRgb.$2, accentRgb.$3, 46),
    );
    img.fillCircle(
      canvas,
      x: 130,
      y: 260,
      radius: 135,
      color: img.ColorRgba8(accentRgb.$1, accentRgb.$2, accentRgb.$3, 34),
    );
    final outPath = p.join(artDir.path, fileName);
    await File(outPath).writeAsBytes(img.encodePng(canvas));
    return outPath;
  }

  Future<String> writeGeometricSticker(
    String fileName,
    (int, int, int, int) fillRgba,
    (int, int, int, int) ringRgba,
    bool diamond,
  ) async {
    final s = img.Image(width: 128, height: 128, numChannels: 4);
    if (diamond) {
      img.fillPolygon(
        s,
        vertices: [
          img.Point(64, 12),
          img.Point(116, 64),
          img.Point(64, 116),
          img.Point(12, 64),
        ],
        color: img.ColorRgba8(
          fillRgba.$1,
          fillRgba.$2,
          fillRgba.$3,
          fillRgba.$4,
        ),
      );
      img.drawCircle(
        s,
        x: 64,
        y: 64,
        radius: 26,
        color: img.ColorRgba8(
          ringRgba.$1,
          ringRgba.$2,
          ringRgba.$3,
          ringRgba.$4,
        ),
      );
    } else {
      img.fillCircle(
        s,
        x: 64,
        y: 64,
        radius: 46,
        color: img.ColorRgba8(
          fillRgba.$1,
          fillRgba.$2,
          fillRgba.$3,
          fillRgba.$4,
        ),
      );
      img.fillCircle(
        s,
        x: 48,
        y: 48,
        radius: 16,
        color: img.ColorRgba8(
          ringRgba.$1,
          ringRgba.$2,
          ringRgba.$3,
          ringRgba.$4,
        ),
      );
    }
    final outPath = p.join(artDir.path, fileName);
    await File(outPath).writeAsBytes(img.encodePng(s));
    return outPath;
  }

  // 1. 沈理青（以内置默认值为基础，不走推导；亮色 textSecondary 改为 #6E757C，其余对比度不足项按 HCT 同色相最小步进补齐并逐项记录）
  final shenliBase =
      ThemeWorkshopStateData.fromAppearance(const ThemeAppearance.empty());
  final defaultLightMap = AppPalette.defaults(Brightness.light).toJson();
  final defaultDarkMap = AppPalette.defaults(Brightness.dark).toJson();
  const defaultCourses = ['#448AFF', '#00C853', '#9C27B0', '#FF5252', '#FF9800'];

  final shenliLightTarget = <String, String>{
    ...defaultLightMap,
    'textSecondary': '#6E757C',
  };
  final shenliLightFixed = ThemeResolver.autoFixVariant(
    brightness: Brightness.light,
    tokens: shenliLightTarget,
    coursePalette: defaultCourses,
  );
  final shenliDarkFixed = ThemeResolver.autoFixVariant(
    brightness: Brightness.dark,
    tokens: defaultDarkMap,
    coursePalette: defaultCourses,
  );

  final shenliDerivedLight = ThemeResolver.deriveTokens(
    seedColor: ThemeContrast.parseColor('#147C72'),
    brightness: Brightness.light,
  );
  final shenliDerivedDark = ThemeResolver.deriveTokens(
    seedColor: ThemeContrast.parseColor('#7ED6C5'),
    brightness: Brightness.dark,
  );
  final shenliFinalLightTokens = {
    ...shenliLightTarget,
    ...shenliLightFixed.changedOverrides,
  };
  final shenliFinalDarkTokens = {
    ...defaultDarkMap,
    ...shenliDarkFixed.changedOverrides,
  };

  final shenliDeltas = <String>[];
  for (final k in defaultLightMap.keys) {
    final before = defaultLightMap[k]!.toUpperCase();
    final after = shenliFinalLightTokens[k]!.toUpperCase();
    if (before != after) {
      shenliDeltas.add('light.tokens.$k: $before → $after');
    }
  }
  for (final k in defaultDarkMap.keys) {
    final before = defaultDarkMap[k]!.toUpperCase();
    final after = shenliFinalDarkTokens[k]!.toUpperCase();
    if (before != after) {
      shenliDeltas.add('dark.tokens.$k: $before → $after');
    }
  }
  for (var i = 0; i < defaultCourses.length; i++) {
    if (shenliLightFixed.coursePalette[i] != defaultCourses[i]) {
      shenliDeltas.add(
        'light.coursePalette[$i]: ${defaultCourses[i]} → ${shenliLightFixed.coursePalette[i]}',
      );
    }
    if (shenliDarkFixed.coursePalette[i] != defaultCourses[i]) {
      shenliDeltas.add(
        'dark.coursePalette[$i]: ${defaultCourses[i]} → ${shenliDarkFixed.coursePalette[i]}',
      );
    }
  }

  shenliBase
    ..name = '沈理青'
    ..author = '沈理校园官方'
    ..description = '沿用沈理校园默认青绿视觉与标准布局，提升次要文字与标签可读性。'
    ..tags = ['简约', '校园', '明暗自适应']
    ..license = 'CC-BY-4.0'
    ..shape = 'standard'
    ..builtinLauncherIcon = 'default'
    ..light = WorkshopVariantDraft(
      seedColor: '#147C72',
      schemeVariant: 'tonalSpot',
      overrides: {
        for (final e in shenliFinalLightTokens.entries)
          if (shenliDerivedLight[e.key] != e.value.toUpperCase())
            e.key: e.value.toUpperCase(),
      },
      coursePalette: shenliLightFixed.coursePalette,
    )
    ..dark = WorkshopVariantDraft(
      seedColor: '#7ED6C5',
      schemeVariant: 'tonalSpot',
      overrides: {
        for (final e in shenliFinalDarkTokens.entries)
          if (shenliDerivedDark[e.key] != e.value.toUpperCase())
            e.key: e.value.toUpperCase(),
      },
      coursePalette: shenliDarkFixed.coursePalette,
    );

  // 2. 墨夜（种子 #5B7C8A，neutral，暗色纯黑 OLED 底面 + compact 页头 + 细描边无阴影）
  final moyeState = ThemeWorkshopStateData(
    draftId: ThemeWorkshopStateData.newUuid(),
    themeId: ThemeWorkshopStateData.newUuid(),
    name: '墨夜',
    author: '沈理校园官方',
    description: '中性岩灰浅色与纯黑高对比深色配对，校园与个人页采用紧凑页头。',
    tags: ['深色', '简约', '高对比'],
    license: 'CC-BY-4.0',
    shape: 'standard',
    light: buildSeededVariant(
      seedHex: '#5B7C8A',
      schemeVariant: 'neutral',
      brightness: Brightness.light,
    )..cardStyle = {'borderWidth': 1.0, 'shadow': 'none'},
    dark: buildSeededVariant(
      seedHex: '#5B7C8A',
      schemeVariant: 'neutral',
      brightness: Brightness.dark,
      overrides: const {
        'background': '#000000',
        'card': '#0E1113',
        'navBackground': '#0A0C0D',
      },
    )..cardStyle = {'borderWidth': 1.0, 'shadow': 'none'},
    layout: {
      'campus': {
        'preset': 'compact',
        'alignment': 'start',
        'imageHeight': 140.0,
        'imageWidth': 1.0,
      },
      'me': {
        'preset': 'compact',
        'alignment': 'start',
        'imageHeight': 140.0,
        'imageWidth': 1.0,
      },
    },
  );

  // 3. 海盐蓝（种子 #2F7FD8，tonalSpot，亮色底 #F5F9FF，8 色蓝绿课表，immersive 页头 + 原创海盐几何背景与贴纸）
  final seaLightBg = await writeGradientBg(
    'sea_light_bg.png',
    (216, 236, 255),
    (236, 248, 252),
    (47, 127, 216),
  );
  final seaDarkBg = await writeGradientBg(
    'sea_dark_bg.png',
    (18, 42, 72),
    (14, 30, 48),
    (112, 186, 255),
  );
  final seaBubble1 = await writeGeometricSticker(
    'sea_bubble_1.png',
    (47, 127, 216, 150),
    (255, 255, 255, 190),
    false,
  );
  final seaBubble2 = await writeGeometricSticker(
    'sea_bubble_2.png',
    (26, 166, 156, 145),
    (230, 252, 250, 180),
    true,
  );
  const seaEightLightRaw = [
    '#2F7FD8',
    '#1E9BB8',
    '#1AA69C',
    '#2E8BC0',
    '#3B6FD8',
    '#26A682',
    '#4B8CE8',
    '#1888A8',
  ];
  const seaEightDarkRaw = [
    '#1D5696',
    '#15687D',
    '#146E66',
    '#1E5E85',
    '#284B94',
    '#196E55',
    '#2B5AA1',
    '#125B70',
  ];
  final seaLight = buildSeededVariant(
    seedHex: '#2F7FD8',
    schemeVariant: 'tonalSpot',
    brightness: Brightness.light,
    overrides: const {'background': '#F5F9FF'},
    customCourses: seaEightLightRaw,
  )
    ..cardStyle = {'borderWidth': 1.0, 'shadow': 'soft'}
    ..decorations['home'] = {
      'background': {
        'image': seaLightBg,
        'fit': 'cover',
        'focalX': 0.5,
        'focalY': 0.5,
        'blur': 0.0,
        'scrim': 0.08,
        'adjustments': {
          'brightness': 6.0,
          'contrast': 106.0,
          'saturation': 108.0,
        },
      },
      'stickers': [
        {'image': seaBubble1, 'x': 0.84, 'y': 0.34, 'width': 0.16, 'rotation': 8.0},
        {'image': seaBubble2, 'x': 0.14, 'y': 0.72, 'width': 0.13, 'rotation': -14.0},
      ],
    }
    ..decorations['me'] = {
      'background': {
        'image': seaLightBg,
        'fit': 'cover',
        'focalX': 0.5,
        'focalY': 0.5,
        'blur': 0.0,
        'scrim': 0.1,
        'adjustments': {
          'brightness': 4.0,
          'contrast': 104.0,
          'saturation': 106.0,
        },
      },
      'stickers': [
        {'image': seaBubble1, 'x': 0.86, 'y': 0.30, 'width': 0.15, 'rotation': -6.0},
      ],
    };
  final seaDark = buildSeededVariant(
    seedHex: '#2F7FD8',
    schemeVariant: 'tonalSpot',
    brightness: Brightness.dark,
    customCourses: seaEightDarkRaw,
  )
    ..cardStyle = {'borderWidth': 1.0, 'shadow': 'soft'}
    ..decorations['home'] = {
      'background': {
        'image': seaDarkBg,
        'fit': 'cover',
        'focalX': 0.5,
        'focalY': 0.5,
        'blur': 0.0,
        'scrim': 0.14,
        'adjustments': {
          'brightness': -6.0,
          'contrast': 108.0,
          'saturation': 96.0,
        },
      },
      'stickers': [
        {'image': seaBubble1, 'x': 0.84, 'y': 0.34, 'width': 0.16, 'rotation': 8.0},
        {'image': seaBubble2, 'x': 0.14, 'y': 0.72, 'width': 0.13, 'rotation': -14.0},
      ],
    }
    ..decorations['me'] = {
      'background': {
        'image': seaDarkBg,
        'fit': 'cover',
        'focalX': 0.5,
        'focalY': 0.5,
        'blur': 0.0,
        'scrim': 0.16,
      },
      'stickers': [
        {'image': seaBubble1, 'x': 0.86, 'y': 0.30, 'width': 0.15, 'rotation': -6.0},
      ],
    };
  final haiyanState = ThemeWorkshopStateData(
    draftId: ThemeWorkshopStateData.newUuid(),
    themeId: ThemeWorkshopStateData.newUuid(),
    name: '海盐蓝',
    author: '沈理校园官方',
    description: '通透海盐蓝白配色与 8 色蓝绿课表，首页与个人页配备沉浸式几何海浪装饰区。',
    tags: ['清新', '浅色', '明暗自适应'],
    license: 'CC-BY-4.0',
    shape: 'standard',
    light: seaLight,
    dark: seaDark,
    layout: {
      'home': {
        'preset': 'immersive',
        'alignment': 'start',
        'imageHeight': 152.0,
        'imageWidth': 1.0,
      },
      'me': {
        'preset': 'immersive',
        'alignment': 'center',
        'imageHeight': 148.0,
        'imageWidth': 0.94,
      },
    },
  );

  // 4. 樱粉（种子 #C9617E，tonalSpot，亮色底 #FFF7F8，rounded 圆角 + 个人页 immersive 几何花瓣贴纸）
  final sakuraLightBg = await writeGradientBg(
    'sakura_light_bg.png',
    (255, 228, 236),
    (255, 245, 247),
    (201, 97, 126),
  );
  final sakuraDarkBg = await writeGradientBg(
    'sakura_dark_bg.png',
    (62, 28, 40),
    (36, 18, 26),
    (235, 146, 172),
  );
  final sakuraPetal = await writeGeometricSticker(
    'sakura_petal.png',
    (216, 112, 142, 155),
    (255, 240, 245, 195),
    true,
  );
  final yingfenLight = buildSeededVariant(
    seedHex: '#C9617E',
    schemeVariant: 'tonalSpot',
    brightness: Brightness.light,
    overrides: const {'background': '#FFF7F8'},
  )
    ..cardStyle = {'borderWidth': 0.5, 'shadow': 'soft'}
    ..decorations['me'] = {
      'background': {
        'image': sakuraLightBg,
        'fit': 'cover',
        'focalX': 0.5,
        'focalY': 0.5,
        'scrim': 0.08,
      },
      'stickers': [
        {'image': sakuraPetal, 'x': 0.85, 'y': 0.28, 'width': 0.15, 'rotation': 18.0},
        {'image': sakuraPetal, 'x': 0.16, 'y': 0.68, 'width': 0.12, 'rotation': -22.0},
      ],
    };
  final yingfenDark = buildSeededVariant(
    seedHex: '#C9617E',
    schemeVariant: 'tonalSpot',
    brightness: Brightness.dark,
  )
    ..cardStyle = {'borderWidth': 0.5, 'shadow': 'soft'}
    ..decorations['me'] = {
      'background': {
        'image': sakuraDarkBg,
        'fit': 'cover',
        'focalX': 0.5,
        'focalY': 0.5,
        'scrim': 0.14,
      },
      'stickers': [
        {'image': sakuraPetal, 'x': 0.85, 'y': 0.28, 'width': 0.15, 'rotation': 18.0},
        {'image': sakuraPetal, 'x': 0.16, 'y': 0.68, 'width': 0.12, 'rotation': -22.0},
      ],
    };
  final yingfenState = ThemeWorkshopStateData(
    draftId: ThemeWorkshopStateData.newUuid(),
    themeId: ThemeWorkshopStateData.newUuid(),
    name: '樱粉',
    author: '沈理校园官方',
    description: '柔和樱粉大圆角卡片与个人页几何花瓣装饰，兼顾深浅双模式清晰对比。',
    tags: ['可爱', '清新', '浅色'],
    license: 'CC-BY-4.0',
    shape: 'rounded',
    light: yingfenLight,
    dark: yingfenDark,
    layout: {
      'campus': {
        'preset': 'compact',
        'alignment': 'start',
        'imageHeight': 136.0,
        'imageWidth': 1.0,
      },
      'me': {
        'preset': 'immersive',
        'alignment': 'center',
        'imageHeight': 148.0,
        'imageWidth': 0.94,
      },
    },
  );

  // 5. 纸感（种子 #3E6B4F，fidelity，亮色底 #F6F0E2 / 卡片 #FBF7EE，compact 圆角与紧凑页头，无阴影细线卡片）
  final zhiganState = ThemeWorkshopStateData(
    draftId: ThemeWorkshopStateData.newUuid(),
    themeId: ThemeWorkshopStateData.newUuid(),
    name: '纸感',
    author: '沈理校园官方',
    description: '温润米白纸张底面配松石墨绿强调色，紧凑圆角与细描边带来安静阅读质感。',
    tags: ['复古', '简约', '浅色'],
    license: 'CC-BY-4.0',
    shape: 'compact',
    light: buildSeededVariant(
      seedHex: '#3E6B4F',
      schemeVariant: 'fidelity',
      brightness: Brightness.light,
      overrides: const {
        'background': '#F6F0E2',
        'card': '#FBF7EE',
      },
    )..cardStyle = {'borderWidth': 1.0, 'shadow': 'none'},
    dark: buildSeededVariant(
      seedHex: '#3E6B4F',
      schemeVariant: 'fidelity',
      brightness: Brightness.dark,
    )..cardStyle = {'borderWidth': 1.0, 'shadow': 'none'},
    layout: {
      'home': {
        'preset': 'compact',
        'alignment': 'start',
        'imageHeight': 136.0,
        'imageWidth': 1.0,
      },
      'me': {
        'preset': 'compact',
        'alignment': 'start',
        'imageHeight': 136.0,
        'imageWidth': 1.0,
      },
    },
  );

  final entries = [
    (
      '01-shenli-qing',
      shenliBase,
      '基于内置默认值，保留全部标准页头布局与内置 `default` 桌面图标，修正浅色次要文字与对比度临界项。',
      '无外部图片/字体资源；使用内置思源黑体与 `ic_launcher_main` (`default`)。',
      shenliDeltas,
    ),
    (
      '02-mo-ye',
      moyeState,
      '种子 `#5B7C8A` (`neutral`)，暗色纯黑 `#000000` 底面与 `#0E1113` 卡片，`campus`/`me` 采用 `compact` 页头与 1dp 无阴影描边。',
      '无外部图片/字体；内置备选桌面图标 `night` 1024×1024 源图待维护者提供后补入安装包，当前按细则第 9 节省略 `launcherIcon`。',
      const <String>[],
    ),
    (
      '03-haiyan-lan',
      haiyanState,
      '种子 `#2F7FD8` (`tonalSpot`)，亮色底 `#F5F9FF` 与 8 色蓝绿课表，`home`/`me` 采用 `immersive` 页头、矩阵调色与柔和卡片阴影。',
      '页头渐变背景与透明几何气泡贴纸由项目程序化原创生成（`CC0-1.0`）；备选图标 `sea` 源图待维护者提供。',
      const <String>[],
    ),
    (
      '04-ying-fen',
      yingfenState,
      '种子 `#C9617E` (`tonalSpot`)，亮色底 `#FFF7F8`，`rounded` 圆角档位，`campus` 采用 `compact`、`me` 采用 `immersive` 页头与几何花瓣贴纸。',
      '页头渐变背景与透明几何花瓣贴纸由项目程序化原创生成（`CC0-1.0`）；备选图标 `sakura` 源图待维护者提供。',
      const <String>[],
    ),
    (
      '05-zhi-gan',
      zhiganState,
      '种子 `#3E6B4F` (`fidelity`)，亮色底 `#F6F0E2`、卡片 `#FBF7EE`，`compact` 圆角与 `home`/`me` 紧凑页头、1dp 纸感细边框无阴影。',
      '霞鹜文楷（`LXGW WenKai`，`OFL-1.1`）GB2312+ASCII 双字重子集字体文件及 `paper` 图标源图未随离线仓库提供，当前不塞入伪造字体或占位图，沿用内置正文回退链。',
      const <String>[],
    ),
  ];

  final out = <_OfficialThemeSpec>[];
  for (final e in entries) {
    final bytes = await e.$2.exportPack(appVersion: '1.7.12');
    out.add(
      _OfficialThemeSpec(
        slug: e.$1,
        state: e.$2,
        bytes: bytes,
        designSummary: e.$3,
        assetNote: e.$4,
        defaultDeltas: e.$5,
      ),
    );
  }
  return out;
}

Future<void> _exportOfficialThemesReportAndScreenshots({
  required WidgetTester tester,
  required List<_OfficialThemeSpec> specs,
  required Map<String, PreparedThemePack> normalizedPacks,
  required Map<String, ThemeCatalogItem> catalogRecords,
}) async {
  tester.view.physicalSize = const Size(1120, 960);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  final reportRoot = Directory(
    p.normalize(
      p.join(
        Directory.current.path,
        '..',
        'docs',
        'reports',
        '2026-11-18-official-themes',
      ),
    ),
  );
  await tester.runAsync(() => reportRoot.create(recursive: true));

  Future<Uint8List> captureStage({
    required ThemeAppearance appearance,
    required Brightness brightness,
    required WorkshopSamplePage page,
    required Map<String, Uint8List> contents,
  }) async {
    final boundaryKey = GlobalKey();
    ImageProvider<Object>? resolveMem(String rawPath) {
      final clean = rawPath.startsWith('/') ? rawPath.substring(1) : rawPath;
      final data = contents[clean] ?? contents[rawPath];
      return data == null ? null : MemoryImage(data);
    }

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(fontFamily: 'NotoSansCJKsc'),
        home: Scaffold(
          body: Center(
            child: DefaultTextStyle.merge(
              style: const TextStyle(fontFamily: 'NotoSansCJKsc'),
              child: RepaintBoundary(
                key: boundaryKey,
                child: SizedBox(
                  width: 390,
                  height: 844,
                  child: ThemeWorkshopSampleStage(
                    appearance: appearance,
                    brightness: brightness,
                    assetResolver: resolveMem,
                    page: page,
                    sampleState: WorkshopSampleState.normal,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    final ctx = boundaryKey.currentContext!;
    final images = tester
        .widgetList<Image>(find.byType(Image))
        .map((image) => image.image)
        .toList();
    if (images.isNotEmpty) {
      await settleEmojiQAImages(tester, ctx, images);
    }
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));

    late Uint8List pngBytes;
    await tester.runAsync(() async {
      final boundary =
          boundaryKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 1.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      pngBytes = byteData!.buffer.asUint8List();
    });
    return pngBytes;
  }

  // 1. 导出沈理青 vs 内置默认外观亮色首页单独对比图
  final shenliPack = normalizedPacks['01-shenli-qing']!;
  final shenliAppearance = const ThemeAppearance.empty().apply(
    shenliPack.manifest,
    ThemeGroup.applicable.intersection(shenliPack.manifest.groups),
    '',
  );
  final compKey = GlobalKey();
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(fontFamily: 'NotoSansCJKsc'),
      home: Scaffold(
        backgroundColor: const Color(0xFFF0F2F5),
        body: Center(
          child: DefaultTextStyle.merge(
            style: const TextStyle(fontFamily: 'NotoSansCJKsc'),
            child: RepaintBoundary(
              key: compKey,
            child: Container(
              color: const Color(0xFFF0F2F5),
              padding: const EdgeInsets.all(12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        '内置默认亮色 (textSecondary #747B82 = 4.29:1)',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: Colors.black87,
                        ),
                      ),
                      const SizedBox(height: 6),
                      SizedBox(
                        width: 360,
                        height: 780,
                        child: ThemeWorkshopSampleStage(
                          appearance: const ThemeAppearance.empty(),
                          brightness: Brightness.light,
                          assetResolver: (_) => null,
                          page: WorkshopSamplePage.home,
                          sampleState: WorkshopSampleState.normal,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: 16),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        '官方主题「沈理青」亮色 (textSecondary #6E757C = 4.67:1)',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: Colors.black87,
                        ),
                      ),
                      const SizedBox(height: 6),
                      SizedBox(
                        width: 360,
                        height: 780,
                        child: ThemeWorkshopSampleStage(
                          appearance: shenliAppearance,
                          brightness: Brightness.light,
                          assetResolver: (_) => null,
                          page: WorkshopSamplePage.home,
                          sampleState: WorkshopSampleState.normal,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.runAsync(() async {
    final shenliDir = Directory(p.join(reportRoot.path, '01-shenli-qing'));
    await shenliDir.create(recursive: true);
    final boundary =
        compKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final imgObj = await boundary.toImage(pixelRatio: 1.0);
    final bd = await imgObj.toByteData(format: ui.ImageByteFormat.png);
    imgObj.dispose();
    await File(
      p.join(shenliDir.path, 'comparison-default-vs-shenli-qing-light.png'),
    ).writeAsBytes(bd!.buffer.asUint8List(), flush: true);
  });

  // 2. 导出全部 5 套官方主题 × 9 个首批页面 × 明暗两套 = 90 张截图
  const pageSlugs = <WorkshopSamplePage, String>{
    WorkshopSamplePage.home: '01-home',
    WorkshopSamplePage.market: '02-market',
    WorkshopSamplePage.schedule: '03-schedule',
    WorkshopSamplePage.campus: '04-campus',
    WorkshopSamplePage.me: '05-me',
    WorkshopSamplePage.userHome: '06-user-home',
    WorkshopSamplePage.settings: '07-settings',
    WorkshopSamplePage.ai: '08-ai',
    WorkshopSamplePage.toolbox: '09-toolbox',
  };

  for (final spec in specs) {
    final pack = normalizedPacks[spec.slug]!;
    final appearance = const ThemeAppearance.empty().apply(
      pack.manifest,
      ThemeGroup.applicable.intersection(pack.manifest.groups),
      '',
    );
    final themeDir = Directory(p.join(reportRoot.path, spec.slug));
    await tester.runAsync(() => themeDir.create(recursive: true));

    for (final brightness in [Brightness.light, Brightness.dark]) {
      final modePrefix = brightness == Brightness.dark ? 'dark' : 'light';
      for (final page in WorkshopSamplePage.values) {
        final png = await captureStage(
          appearance: appearance,
          brightness: brightness,
          page: page,
          contents: pack.contents,
        );
        final outFile = File(
          p.join(themeDir.path, '$modePrefix-${pageSlugs[page]}.png'),
        );
        await tester.runAsync(() => outFile.writeAsBytes(png, flush: true));
      }
    }
  }

  // 3. 写入制作记录与素材许可台账 README.md
  final shenliSpec = specs.first;
  final md = StringBuffer()
    ..writeln('# P5 首批官方主题制作记录、许可台账与九页明暗归档')
    ..writeln()
    ..writeln('生成日期：2026-11-18')
    ..writeln('验证环境：隔离回环 Go 服务端 + Flutter 共享组件渲染舞台（390×844）')
    ..writeln()
    ..writeln('## 1. 已完成首批五套官方主题总览')
    ..writeln()
    ..writeln('五套官方主题共用现有单套 Flutter 组件体系，对比度检查全部为 0 告警，并已在隔离环境中通过维护者管理员账号（`source=official`）投稿、第二名管理员账号审核上架，`GET /api/themes?sort=official` 严格按下列顺序返回：')
    ..writeln()
    ..writeln('| 顺序 | 名称 | 目录 | 种子色 / 方案 | 圆角 | 页头模板与卡片样式 | 规范包大小 | 规范包 SHA-256 |')
    ..writeln('| --- | --- | --- | --- | --- | --- | --- | --- |');
  for (var i = 0; i < specs.length; i++) {
    final s = specs[i];
    final rec = catalogRecords[s.slug]!;
    final layoutDesc = s.state.layout.isEmpty
        ? '全部默认 `standard`'
        : s.state.layout.entries
            .map((e) => '${e.key}:`${e.value['preset']}`')
            .join('、');
    final csDesc = s.state.light.cardStyle == null
        ? '默认卡片描边/阴影'
        : '描边 `${s.state.light.cardStyle!['borderWidth']}dp` / 阴影 `${s.state.light.cardStyle!['shadow']}`';
    md.writeln(
      '| ${i + 1} | **${s.state.name}** | `${s.slug}/` | `${s.state.light.seedColor}` / `${s.state.light.schemeVariant}` | `${s.state.shape}` | $layoutDesc；$csDesc | ${rec.packageSize} B | `${rec.packageSha256}` |',
    );
  }

  md
    ..writeln()
    ..writeln('## 2. 「沈理青」与内置默认外观的有意视觉差异单列验收')
    ..writeln()
    ..writeln('按制作细则第 9 节与契约第 3 节，「沈理青」不走种子色推导，直接以内置默认 `AppPalette.defaults` 为基础制作，保持全部默认标准布局。为满足商城上架的 WCAG 2.1 对比度门禁（正文与标签 ≥ 4.5:1），对内置默认值做了以下同色相最小色调步进修正：')
    ..writeln();
  for (final d in shenliSpec.defaultDeltas) {
    md.writeln('- `$d`');
  }
  md
    ..writeln()
    ..writeln('- 并排对比图：`01-shenli-qing/comparison-default-vs-shenli-qing-light.png`（左为内置默认亮色 `#747B82` = 4.29:1，右为官方主题「沈理青」亮色 `#6E757C` = 4.67:1）。')
    ..writeln()
    ..writeln('## 3. 素材来源与许可证台账')
    ..writeln()
    ..writeln('| 主题 | 主题包协议 | 包含资源文件 | 来源与版权说明 |')
    ..writeln('| --- | --- | --- | --- |');
  for (final s in specs) {
    final pack = normalizedPacks[s.slug]!;
    final assetList =
        pack.manifest.assets.map((a) => '`${a.path}`').toSet().join('、');
    md.writeln(
      '| ${s.state.name} | `${s.state.license}` | $assetList | ${s.assetNote} |',
    );
  }

  md
    ..writeln()
    ..writeln('## 4. 缺少的维护者素材与未记为完成项说明')
    ..writeln()
    ..writeln('以下项目因外部或维护者专属素材尚未提供，严格遵守“不拿重复占位图或未授权素材冒充完成”的规则单列说明：')
    ..writeln()
    ..writeln('1. **第六套官方主题「校园四季」（未制作、不计入已完成）**：需维护者提供 4 张拥有完整授权的沈阳理工大学校园实景照片（全局、首页、课表、我各一张）及全套 `template` 线性导航图标源图，待照片合入后再行制作。')
    ..writeln('2. **「纸感」外部霞鹜文楷字体文件（待补入新版本）**：离线工作区未附带 `LXGW WenKai`（`OFL-1.1`）TTF/OTF 源文件，当前 v1 包未嵌入伪造字体文件，正文回退使用内置 `NotoSansCJKsc`；待维护者提供子集化常规体与粗体文件后发布「纸感」v2。')
    ..writeln('3. **5 套非默认内置备选桌面图标源图（`night` / `sea` / `sakura` / `paper` / `campus`）**：需维护者提供 1024×1024 前景、背景色与中间 66% 单色透明剪影三件套源图随客户端发版打包；源图到位前仅「沈理青」声明 `launcherIcon.builtin = "default"`，其余 4 套按制作细则第 9 节省略 `launcherIcon`。')
    ..writeln('4. **生产环境上架**：本次仅在隔离回环服务端完成双管理员投稿与审核验证；正式生产环境投稿与审核须由维护者授权后使用真实管理员账号执行。')
    ..writeln()
    ..writeln('## 5. 九个首批页面明暗两套截图索引（共 90 张 + 1 张默认对比图）')
    ..writeln();
  for (final s in specs) {
    md
      ..writeln('### ${s.state.name}（`${s.slug}`）')
      ..writeln('- 设计与参数摘要：${s.designSummary}')
      ..writeln('- 亮色九页：`light-01-home.png`、`light-02-market.png`、`light-03-schedule.png`、`light-04-campus.png`、`light-05-me.png`、`light-06-user-home.png`、`light-07-settings.png`、`light-08-ai.png`、`light-09-toolbox.png`')
      ..writeln('- 暗色九页：`dark-01-home.png`、`dark-02-market.png`、`dark-03-schedule.png`、`dark-04-campus.png`、`dark-05-me.png`、`dark-06-user-home.png`、`dark-07-settings.png`、`dark-08-ai.png`、`dark-09-toolbox.png`')
      ..writeln();
  }

  await tester.runAsync(() async {
    await File(p.join(reportRoot.path, 'README.md'))
        .writeAsString(md.toString(), flush: true);
  });
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
