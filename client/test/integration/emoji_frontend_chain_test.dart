import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/features/emoji/application/emoji_recent_manager.dart';
import 'package:shenliyuan/features/emoji/data/emoji_pack_runtime.dart';
import 'package:shenliyuan/features/emoji/data/emoji_submission_repository.dart';
import 'package:shenliyuan/features/emoji/domain/emoji_asset_ref.dart';
import 'package:shenliyuan/features/emoji/presentation/emoji_creator_screen.dart';
import 'package:shenliyuan/features/emoji/presentation/emoji_import_screen.dart';
import 'package:shenliyuan/features/emoji/presentation/emoji_management_screen.dart';
import 'package:shenliyuan/features/emoji/presentation/emoji_submissions_screen.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/config/api_constants.dart';
import 'package:shenliyuan/controllers/post_reply_composer_controller.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/services/emoji_favorite_service.dart';
import 'package:shenliyuan/services/publish_session_scope.dart';
import 'package:shenliyuan/services/post_reply_service.dart';
import 'package:shenliyuan/widgets/emoji/app_emoji_panel.dart';
import 'package:shenliyuan/widgets/emoji/sticker_catalog.dart';

import '../helpers/emoji_flow_qa.dart';
import '../helpers/golden_test_app.dart';
import '../helpers/golden_viewport.dart';

// 显式 opt-in 的本机联调，真实 TLS API 与文件；不 mock 业务响应、不使用真实登录账号。
class _TLS extends HttpOverrides {
  _TLS(String certificate)
      : context = SecurityContext(withTrustedRoots: false)
          ..setTrustedCertificatesBytes(utf8.encode(certificate));
  final SecurityContext context;
  final clients = <HttpClient>[];
  @override
  HttpClient createHttpClient(SecurityContext? _) => client();
  HttpClient client() {
    final client = super.createHttpClient(context);
    clients.add(client);
    return client;
  }

  void close() {
    for (final client in clients) {
      client.close(force: true);
    }
  }
}

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
}

class _Role extends AuthProvider {
  _Role(this.api, this.id, this.jwt) : super(Dio(), loadStoredAuth: false);
  final Dio api;
  final int id;
  final String jwt;
  @override
  Dio get dio => api;
  @override
  User get user => User(
      id: id,
      studentId: '',
      nickname: 'user-$id',
      role: id == 3 ? 'admin' : 'user',
      createdAt: DateTime(2026));
  @override
  bool get isLoggedIn => true;
  @override
  String get token => jwt;
}

Future<void> _until(WidgetTester tester, bool Function() done,
    {String reason = '链路未在限定时间完成'}) async {
  for (var i = 0; i < 600; i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 15)));
    await tester.pump(const Duration(milliseconds: 25));
    if (done()) {
      await tester.pump(const Duration(milliseconds: 350));
      return;
    }
  }
  expect(done(), isTrue, reason: reason);
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await _until(tester, () => finder.evaluate().isNotEmpty,
      reason: '操作入口未出现：$finder');
  await tester.ensureVisible(finder.first);
  await tester.pump(const Duration(milliseconds: 350));
  expect(finder.first.hitTestable(), findsOneWidget);
  await tester.tap(finder.first);
  await tester.pump();
}

// 连接池的 socket 可能先由 Widget 发起，需同时推进其测试 zone 与真实网络事件。
Future<T> _network<T>(WidgetTester tester, Future<T> Function() work) async {
  T? result;
  Object? failure;
  StackTrace? failureStack;
  var done = false;
  work().then((value) {
    result = value;
    done = true;
  }, onError: (Object error, StackTrace stack) {
    failure = error;
    failureStack = stack;
    done = true;
  });
  await _until(tester, () => done, reason: '真实 API 请求未完成');
  if (failure is DioException) {
    final error = failure as DioException;
    debugPrint('emoji-chain: API failure ${error.requestOptions.path}: '
        '${error.response?.statusCode} ${error.response?.data}');
  }
  if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
  return result as T;
}

void main() {
  final configPath = Platform.environment['EMOJI_CHAIN_CONFIG'];
  setUpAll(loadEmojiQAFonts);
  testWidgets('真实 Go API：导入→申请→开通→制作→审核→下载→面板选择→下架', (tester) async {
    final config = jsonDecode(
            (await tester.runAsync(() => File(configPath!).readAsString()))!)
        as Map;
    expect(Uri.parse(config['base_url'] as String).host, '127.0.0.1');
    expect(ApiConstants.baseUrl, config['base_url'],
        reason: '必须用脚本注入的隔离 API，禁止默认入口访问生产服务');
    final tls = _TLS(config['certificate'] as String);
    final previousHttp = HttpOverrides.current;
    HttpOverrides.global = tls;
    final clients = <Dio>[];
    Dio api([int? id]) {
      final dio = Dio(BaseOptions(
          baseUrl: config['base_url'] as String,
          headers: {
            if (id != null) 'Authorization': 'Bearer ${config['tokens']['$id']}'
          },
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 10)));
      dio.httpClientAdapter = IOHttpClientAdapter(createHttpClient: tls.client);
      clients.add(dio);
      return dio;
    }

    final author = _Role(api(1), 1, config['tokens']['1'] as String);
    final admin = _Role(api(3), 3, config['tokens']['3'] as String);
    final reader = _Role(api(2), 2, config['tokens']['2'] as String);
    final public = api();
    final root = await tester
        .runAsync(() => Directory.systemTemp.createTemp('emoji-live-chain-'));
    final oldPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root!.path);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      HttpOverrides.global = previousHttp;
      tls.close();
      for (final dio in clients) {
        dio.close(force: true);
      }
      author.dispose();
      admin.dispose();
      reader.dispose();
      PathProviderPlatform.instance = oldPaths;
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      for (var attempt = 0;; attempt++) {
        try {
          await root.delete(recursive: true);
          break;
        } on FileSystemException {
          if (attempt == 9) rethrow;
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
    });
    await setGoldenViewport(tester, GoldenViewports.phone360x800);
    final prefs = MemoryPreferencesStore();
    final recent = EmojiRecentManager(preferencesLoader: () async => prefs)
      ..switchUser('1');
    final favorites =
        EmojiFavoriteService(preferencesLoader: () async => prefs);
    final store = await tester.runAsync(() => EmojiPackRuntime.forAccount('1'));
    final screenshot = GlobalKey();
    Future<void> mount(_Role role, Widget screen) async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(ChangeNotifierProvider<AuthProvider>.value(
          value: role,
          child: RepaintBoundary(
              key: screenshot, child: GoldenTestApp(home: screen))));
      await tester.pump();
    }

    final files = <File>[];
    await tester.runAsync(() async {
      for (final sticker in appStickerGroups.first.items.take(2)) {
        final data = await rootBundle.load(sticker.thumbnailAsset);
        files.add(await File('${root.path}/${sticker.label}.png')
            .writeAsBytes(data.buffer.asUint8List()));
      }
    });
    await mount(
        author,
        Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                            builder: (_) => EmojiImportScreen(
                                store: store!,
                                recentManager: recent,
                                pickImages: () async => files))),
                    child: const Text('开始导入')))));
    await _tap(tester, find.text('开始导入'));
    await _tap(tester, find.text('从相册选择'));
    await _until(tester, () => find.text('确认导入并使用').evaluate().isNotEmpty);
    await tester.enterText(find.byType(TextField), '本机联调素材');
    FocusManager.instance.primaryFocus?.unfocus();
    await _tap(tester, find.text('确认导入并使用'));
    await _until(tester, () => find.text('开始导入').evaluate().isNotEmpty);
    expect((await tester.runAsync(store!.load))!.single.isCatalogPack, isFalse);
    debugPrint('emoji-chain: imported locally');

    await mount(
        author,
        EmojiManagementScreen(
            store: store, recentManager: recent, favoriteService: favorites));
    await _until(tester, () => find.text('本机联调素材').evaluate().isNotEmpty);
    await _tap(tester, find.text('创作中心'));
    debugPrint('emoji-chain: opened creator application');
    await _until(tester, () => find.text('提交创作者申请').evaluate().isNotEmpty);
    await tester.enterText(find.byType(TextField), '本机完整链路验证素材');
    FocusManager.instance.primaryFocus?.unfocus();
    await _tap(tester, find.byType(CheckboxListTile));
    await _tap(tester, find.text('提交创作者申请'));
    await _until(tester,
        () => find.text('申请已提交，请等待管理员处理。审核结果会在这里显示。').evaluate().isNotEmpty);
    expect(
        (await _network(
                tester,
                () => public.get('/emoji/packs',
                    queryParameters: {'include_community': true})))
            .data,
        isNot(contains(containsPair('name', '联调公开作品'))));

    await mount(admin, const EmojiCreatorReviewScreen());
    await _until(tester, () => find.text('开通权限').evaluate().isNotEmpty);
    await _tap(tester, find.text('开通权限'));
    await _tap(tester, find.widgetWithText(FilledButton, '开通创作者权限'));
    await _until(tester, () => find.text('暂无对应申请').evaluate().isNotEmpty);

    await mount(author, EmojiCreatorScreen(store: store));
    await _until(tester, () => find.text('制作表情包').evaluate().isNotEmpty);
    await _tap(tester, find.text('制作表情包'));
    await _until(tester, () => find.text('本机联调素材').evaluate().isNotEmpty);
    await _tap(tester, find.text('本机联调素材'));
    await _until(tester, () => find.text('公开名称').evaluate().isNotEmpty);
    await tester.enterText(find.widgetWithText(TextField, '公开名称'), '联调公开作品');
    await tester.enterText(
        find.byKey(const ValueKey('emoji-label-image-1')), '收到联调');
    const edgeLabel = '兼容<3&\u2028\u2029\\u2028';
    final edgeField = find.byKey(const ValueKey('emoji-label-image-2'));
    await tester.ensureVisible(edgeField);
    await tester.enterText(edgeField, edgeLabel);
    await _tap(tester, find.text('设为封面').last);
    await _tap(tester, find.text('设为面板图标').last);
    FocusManager.instance.primaryFocus?.unfocus();
    await _tap(tester, find.text('预览上架效果'));
    await _until(tester, () => find.text('上架效果预览').evaluate().isNotEmpty);
    expect(
        find.byWidgetPredicate(
            (widget) => widget is Text && widget.data == '收到联调'),
        findsOneWidget);
    await captureEmojiQA(tester, screenshot, 'live-chain-creator-preview');
    await _tap(tester, find.byTooltip('返回'));
    await _tap(tester, find.byType(CheckboxListTile));
    await _until(
        tester,
        () =>
            tester
                .widget<FilledButton>(find.widgetWithText(FilledButton, '提交审核'))
                .onPressed !=
            null);
    await _tap(tester, find.text('提交审核'));
    await _until(
        tester, () => find.text('已提交审核，结果可在我的作品查看').evaluate().isNotEmpty);
    const session = PublishSessionScope(accountId: 1, accountSessionEpoch: 0);
    final mine = (await _network(
            tester,
            () => EmojiSubmissionRepository(author.api)
                .list(session: session, token: CancelToken())))
        .items
        .single;
    expect(mine.status, 'pending');
    expect(mine.coverAssetId, 'image-2');
    expect(mine.iconAssetId, 'image-2');
    debugPrint('emoji-chain: submitted immutable release');

    await mount(admin, const EmojiSubmissionsScreen(admin: true));
    await _until(tester, () => find.text('联调公开作品').evaluate().isNotEmpty);
    await _tap(tester, find.text('联调公开作品'));
    await _until(tester, () => find.text('通过并上架').evaluate().isNotEmpty);
    await _tap(tester, find.text('通过并上架'));
    await _tap(tester, find.widgetWithText(FilledButton, '通过并上架').last);
    await _until(tester, () => find.text('下架表情包').evaluate().isNotEmpty);

    recent.switchUser('2');
    final readerStore =
        (await tester.runAsync(() => EmojiPackRuntime.forAccount('2')))!;
    String? selectedPath;
    EmojiAssetRef? selectedAsset;
    await mount(
        reader,
        Scaffold(
            body: SizedBox(
                height: 330,
                child: AppEmojiPanel(
                    recentManager: recent,
                    favoriteService: favorites,
                    onEmojiSelected: (_) {},
                    onBackspace: () {},
                    onPackAssetSelected: (path, asset) {
                      selectedPath = path;
                      selectedAsset = asset;
                    }))));
    await _tap(tester, find.byTooltip('表情管理'));
    await _until(
        tester,
        () =>
            tester
                .widget<TextButton>(
                    find.widgetWithText(TextButton, '表情商城 · 免费'))
                .onPressed !=
            null);
    await _tap(tester, find.text('表情商城 · 免费'));
    await _until(tester, () => find.text('联调公开作品').evaluate().isNotEmpty);
    await _tap(tester, find.text('联调公开作品'));
    await _until(tester, () => find.text('收到联调').evaluate().isNotEmpty);
    await captureEmojiQA(tester, screenshot, 'live-chain-store-detail');
    await _tap(tester, find.text('免费下载并添加'));
    await _until(tester, () => find.text('返回使用').evaluate().isNotEmpty,
        reason: '真实 Manifest/资源校验和安装失败');
    await _tap(tester, find.text('返回使用'));
    await _until(
        tester,
        () => find
            .byKey(ValueKey('emoji-search-${mine.catalogId}'))
            .evaluate()
            .isNotEmpty,
        reason: '商城返回后未自动选中已安装包');
    final installed = (await tester.runAsync(readerStore.load))!.single;
    expect(installed.packId, mine.catalogId);
    expect(find.byKey(ValueKey('installed-pack-title-${mine.catalogId}')),
        findsOneWidget,
        reason: '返回后标题与选中包必须同步');
    expect(installed.coverAssetId, 'image-2');
    expect(installed.iconAssetId, 'image-2');
    expect(installed.authorName, 'user-1');
    expect(installed.manifest.assets.first.name, '收到联调');
    expect(installed.manifest.assets.last.name, '兼容<3&  \\u2028',
        reason: '沿用服务端行分隔符转空格规则，HTML/反斜线及规范化 Hash 需要兼容');
    await _until(
        tester,
        () => find
            .byKey(ValueKey('emoji-search-${mine.catalogId}'))
            .evaluate()
            .isNotEmpty);
    await tester.enterText(
        find.byKey(ValueKey('emoji-search-${mine.catalogId}')), '不存在的文字');
    await tester.pump();
    expect(find.text('没有找到对应表情，试试其他文字'), findsOneWidget);
    await tester.enterText(
        find.byKey(ValueKey('emoji-search-${mine.catalogId}')), '收到');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    await _tap(tester, find.bySemanticsLabel('收到联调'));
    expect(selectedAsset!.assetKey, 'local:${mine.catalogId}:image-1');
    final selectedBytes =
        await tester.runAsync(() => File(selectedPath!).readAsBytes());
    expect(
        sha256.convert(selectedBytes!).toString(), selectedAsset!.contentHash);
    expect(selectedAsset!.mimeType, 'image/png');
    await captureEmojiQA(tester, screenshot, 'live-chain-installed-panel');
    final composer = PostReplyComposerController();
    addTearDown(composer.dispose);
    composer.selectLocalImage(XFile(selectedPath!), emojiAsset: selectedAsset);
    final reply = (await _network(
        tester,
        () => PostReplyService(reader.api, recentManager: recent)
            .submit(1, composer.draft)));
    expect(reply.assetKey, selectedAsset!.assetKey);
    expect(reply.packId, mine.catalogId);
    expect(reply.images.single.fileId, greaterThan(0));
    expect((await tester.runAsync(recent.load))!.single.key.serialized,
        selectedAsset!.assetKey);
    debugPrint('emoji-chain: comment upload and submission confirmed');
    recent.switchUser('1');
    await _until(
        tester,
        () => find
            .byKey(ValueKey('installed-pack-${mine.catalogId}'))
            .evaluate()
            .isEmpty);

    await _network(
        tester,
        () => EmojiSubmissionRepository(admin.api).review(
            mine.id, 'unpublish', '隔离联调下架验证',
            session:
                const PublishSessionScope(accountId: 3, accountSessionEpoch: 0),
            token: CancelToken()));
    final unavailable = await _network(
        tester,
        () => public.get('/emoji/packs/${mine.catalogId}/assets/image-1',
            queryParameters: {'version': 1},
            options: Options(validateStatus: (_) => true)));
    expect(unavailable.statusCode, 404);
    final commentImage = await _network(
        tester,
        () => public.get(
            '${(config['base_url'] as String).replaceFirst(RegExp(r'/api$'), '')}${reply.images.single.originUrl}',
            options: Options(responseType: ResponseType.bytes)));
    expect(commentImage.statusCode, 200, reason: '作品下架后已经发送的评论图片继续可读取');
    expect((await tester.runAsync(readerStore.load))!.single.packId,
        mine.catalogId,
        reason: '下架不擦除已有本机安装');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    tls.close();
    await tester.pump();
  }, skip: configPath == null, timeout: const Timeout(Duration(minutes: 3)));
}
