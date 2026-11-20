import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/features/emoji/application/emoji_pack_importer.dart';
import 'package:shenliyuan/features/emoji/application/emoji_pack_installer.dart';
import 'package:shenliyuan/features/emoji/data/emoji_pack_local_store.dart';
import 'package:shenliyuan/features/emoji/presentation/emoji_submissions_screen.dart';
import 'package:shenliyuan/features/emoji/presentation/emoji_creator_screen.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/widgets/emoji/sticker_catalog.dart';
import '../../helpers/emoji_flow_qa.dart';
import '../../helpers/golden_test_app.dart';
import '../../helpers/golden_viewport.dart';

late Uint8List _imageBytes;

class _Auth extends AuthProvider {
  _Auth(super.dio) : super(loadStoredAuth: false);
  int epoch = 0;
  User active = User(
      id: 3,
      studentId: '',
      nickname: '测试管理员',
      role: 'admin',
      createdAt: DateTime(2026));
  @override
  User get user => active;
  @override
  bool get isLoggedIn => true;
  @override
  String get token => 'fixture-token';
  @override
  int get accountSessionEpoch => epoch;
  void change({int id = 4, String role = 'user'}) {
    active = User(
        id: id,
        studentId: '',
        nickname: '其他用户',
        role: role,
        createdAt: DateTime(2026));
    epoch++;
    notifyListeners();
  }
}

Map<String, dynamic> _item({String status = 'pending', bool assets = false}) =>
    {
      'id': 'community-fixture',
      'name': '校园日常',
      'description': '常用的校园反应表情',
      'user_id': 1,
      'status': status,
      'asset_count': 4,
      'total_size': 10240,
      'review_reason': status == 'rejected' ? '请补充作者授权说明' : '',
      if (assets)
        'assets': [
          for (var i = 0; i < 4; i++)
            {
              'id': 'image-${i + 1}',
              'name': ['亲亲', '粘', '认真', '抱'][i],
              'animated': false
            }
        ],
    };

class _Api {
  final dio = Dio(BaseOptions(baseUrl: 'https://fixture.test/api'));
  late final auth = _Auth(dio);
  final requests = <RequestOptions>[];
  bool fail = false, empty = false;
  int failureStatus = 503;
  String status = 'pending';
  String creatorStatus = 'active';
  Future<Map<String, dynamic>>? creatorResponse;
  Future<Object> Function(RequestOptions)? respond;
  _Api() {
    dio.interceptors
        .add(InterceptorsWrapper(onRequest: (options, handler) async {
      requests.add(options);
      if (fail) {
        handler.reject(DioException(
            requestOptions: options,
            response: Response(
                requestOptions: options,
                statusCode: failureStatus,
                data: {'error': '网络暂不可用'})));
        return;
      }
      final Object data;
      if (options.path == '/emoji/creator') {
        if (options.method == 'POST') creatorStatus = 'pending';
        data = creatorResponse != null
            ? await creatorResponse!
            : {
                'status': creatorStatus,
                'user_id': 3,
                'version': creatorStatus == 'none' ? 0 : 1,
                'description': creatorStatus == 'none' ? '' : '校园日常原创表情'
              };
      } else if (options.path == '/admin/emoji-creators') {
        data = {
          'items': [
            {
              'status': 'pending',
              'user_id': 1,
              'version': 1,
              'description': '校园日常原创表情'
            }
          ],
          'total': 1
        };
      } else if (respond != null) {
        data = await respond!(options);
      } else if (options.path.contains('/assets/')) {
        data = _imageBytes;
      } else if (options.path.endsWith('/review')) {
        status = (options.data as Map)['action'] == 'approve'
            ? 'published'
            : 'rejected';
        data = <String, dynamic>{};
      } else if (options.method == 'POST') {
        data = _item();
      } else if (options.path.endsWith('/community-fixture')) {
        data = _item(status: status, assets: true);
      } else {
        data = {
          'items': empty
              ? []
              : [
                  _item(
                      status: options.queryParameters['status'] as String? ??
                          status)
                ],
          'total': empty ? 0 : 1
        };
      }
      handler.resolve(
          Response(requestOptions: options, statusCode: 200, data: data));
    }));
  }
}

Future<GlobalKey> _mount(WidgetTester tester, _Api api, Widget screen,
    {String profile = 'light'}) async {
  await setGoldenViewport(tester, GoldenViewports.phone360x800);
  final key = GlobalKey();
  await tester.pumpWidget(ChangeNotifierProvider<AuthProvider>.value(
      value: api.auth,
      child: RepaintBoundary(
          key: key,
          child: GoldenTestApp(
              home: screen,
              themeMode: profile == 'dark' ? ThemeMode.dark : ThemeMode.light,
              textScaler: TextScaler.linear(profile == 'stress'
                  ? 1.5
                  : profile == 'large'
                      ? 1.3
                      : 1)))));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 20));
  for (var frame = 0; frame < 6; frame++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump(const Duration(milliseconds: 20));
  }
  await settleEmojiQAImages(tester, key.currentContext!,
      tester.widgetList<Image>(find.byType(Image)).map((image) => image.image));
  await tester.pump();
  return key;
}

void main() {
  setUpAll(loadEmojiQAFonts);
  late Directory root;
  late EmojiPackLocalStore store;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('emoji-submission-screen-');
    store = EmojiPackLocalStore(Directory('${root.path}/store'));
    final content = (await rootBundle
            .load(appStickerGroups.first.items.first.thumbnailAsset))
        .buffer
        .asUint8List();
    _imageBytes = content;
    final files = <File>[];
    for (final sticker in appStickerGroups.first.items.take(4)) {
      files.add(await File('${root.path}/${sticker.label}.png').writeAsBytes(
          (await rootBundle.load(sticker.thumbnailAsset))
              .buffer
              .asUint8List()));
    }
    final importer = EmojiPackImporter(EmojiPackInstaller(store));
    final pack = await importer
        .installPrepared(await importer.prepareImages(files), name: '校园日常');
    // 使用实际图片字节预热缩略图，避免 Windows native FileImage mmap 持有临时目录。
    final codec = await ui.instantiateImageCodec(content);
    final frame = await codec.getNextFrame();
    codec.dispose();
    PaintingBinding.instance.imageCache.putIfAbsent(
        FileImage(File(
            '${store.versionDirectory(pack.packId, pack.version).path}/${pack.manifest.assets.first.path}')),
        () => OneFrameImageStreamCompleter(
            Future.value(ImageInfo(image: frame.image))));
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });

  for (final profile in ['light', 'dark', 'large', 'stress']) {
    testWidgets('审核详情渲染与驳回原因校验 $profile', (tester) async {
      final api = _Api();
      final key = await _mount(
          tester,
          api,
          const EmojiSubmissionDetailScreen(
              id: 'community-fixture', admin: true),
          profile: profile);
      await tester.pumpAndSettle();
      expect(find.text('校园日常'), findsOneWidget);
      expect(find.text('通过并上架'), findsOneWidget);
      await captureEmojiQA(tester, key, 'review-$profile');
      await tester.tap(find.text('驳回并说明原因'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '驳回'));
      await tester.pumpAndSettle();
      expect(find.text('请填写原因，帮助投稿人改进'), findsOneWidget);
      expect(api.requests.where((r) => r.path.endsWith('/review')), isEmpty);
      await tester.enterText(find.byType(TextFormField), '请补充作者授权说明');
      tester.testTextInput.hide();
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '驳回'));
      await tester.pumpAndSettle();
      expect(find.textContaining('已驳回'), findsOneWidget);
      expect(find.textContaining('请补充作者授权说明'), findsOneWidget);
      expect(
          api.requests.where((r) => r.path.endsWith('/review')), hasLength(1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('审核列表加载失败重试，筛选空态与分页会话预期', (tester) async {
    final api = _Api()..fail = true;
    await _mount(tester, api, const EmojiSubmissionsScreen(admin: true));
    await tester.pumpAndSettle();
    expect(find.text('网络暂不可用'), findsOneWidget);
    api.fail = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('校园日常'), findsOneWidget);
    expect(api.requests.last.extra['expectedAuthUserId'], 3);
    expect(api.requests.last.extra['expectedAuthSessionEpoch'], 0);
    api.empty = true;
    await tester.tap(find.text('已上架'));
    await tester.pumpAndSettle();
    expect(find.text('暂无已上架的表情包'), findsOneWidget);
    expect(api.requests.last.queryParameters['status'], 'published');
    expect(tester.takeException(), isNull);
  });

  testWidgets('切号取消未完成列表；旧返回不能泄露到新账号', (tester) async {
    final hold = Completer<Object>();
    final api = _Api()..respond = (_) => hold.future;
    await _mount(tester, api, const EmojiSubmissionsScreen(admin: true));
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    api.auth.change();
    hold.complete({
      'items': [_item()],
      'total': 1
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('账号或权限已变化'), findsOneWidget);
    expect(find.text('校园日常'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('审核弹窗撤权后立即隐藏内容且不发送处理请求', (tester) async {
    final api = _Api();
    await _mount(
        tester,
        api,
        const EmojiSubmissionDetailScreen(
            id: 'community-fixture', admin: true));
    await tester.pumpAndSettle();
    await tester.tap(find.text('通过并上架'));
    await tester.pumpAndSettle();
    api.auth.change(id: 3, role: 'user');
    await tester.pumpAndSettle();
    expect(find.textContaining('符合公开分享要求'), findsNothing);
    expect(find.widgetWithText(FilledButton, '通过并上架'), findsNothing);
    expect(api.requests.where((r) => r.path.endsWith('/review')), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('服务端拒绝管理员操作后清空旧详情并关闭处理入口', (tester) async {
    final api = _Api();
    await _mount(
        tester,
        api,
        const EmojiSubmissionDetailScreen(
            id: 'community-fixture', admin: true));
    await tester.pumpAndSettle();
    api.fail = true;
    api.failureStatus = 403;
    await tester.tap(find.text('通过并上架'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '通过并上架').last);
    await tester.pumpAndSettle();
    expect(find.text('校园日常'), findsNothing);
    expect(find.textContaining('账号或权限已变化'), findsOneWidget);
    expect(find.text('通过并上架'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final profile in ['light', 'dark', 'large', 'stress']) {
    testWidgets('创作中心真实渲染与权限入口 $profile', (tester) async {
      final api = _Api();
      final key = await _mount(tester, api, EmojiCreatorScreen(store: store),
          profile: profile);
      await waitForEmojiWork(tester);
      expect(find.text('创作者权限已开通'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '制作表情包'), findsOneWidget);
      await captureEmojiQA(tester, key, 'creator-center-$profile');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
    testWidgets('制作编辑与上架预览真实渲染 $profile', (tester) async {
      final api = _Api();
      final key = await _mount(
          tester, api, EmojiSubmissionUploadScreen(store: store),
          profile: profile);
      await waitForEmojiWork(tester);
      await tester.tap(find.text('校园日常'));
      await tester.pump();
      await waitForEmojiWork(tester);
      final label = find.byKey(const ValueKey('emoji-label-image-1'));
      await tester.scrollUntilVisible(label, 180,
          scrollable: find.byType(Scrollable).first);
      await tester.enterText(label, '收到');
      if (profile == 'stress') {
        tester.view.viewInsets = const FakeViewPadding(bottom: 300);
        addTearDown(tester.view.resetViewInsets);
        await tester.pump();
        await tester.ensureVisible(label);
        await captureEmojiQA(tester, key, 'creator-keyboard-stress');
        expect(tester.takeException(), isNull);
        tester.view.resetViewInsets();
        await tester.pump();
      }
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      await captureEmojiQA(tester, key, 'creator-editor-$profile');
      await tester.tap(find.text('预览上架效果'));
      await tester.pumpAndSettle();
      expect(find.text('本机草稿 · 尚未上架 · 审核通过后免费下载'), findsOneWidget);
      expect(find.text('免费下载并添加'), findsNothing);
      await captureEmojiQA(tester, key, 'creator-preview-$profile');
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView).last, const Offset(0, 700));
      await tester.pump();
      await waitForEmojiWork(tester);
      expect(find.text('本机草稿已保存 · 尚未公开'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
  testWidgets('创作者申请失败可重试，确认规则后申请仍需审核', (tester) async {
    final api = _Api()
      ..creatorStatus = 'none'
      ..fail = true;
    await _mount(tester, api, EmojiCreatorScreen(store: store));
    expect(find.text('网络暂不可用'), findsOneWidget);
    api.fail = false;
    await tester.tap(find.text('重试'));
    await tester.pump();
    await waitForEmojiWork(tester);
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '提交创作者申请'))
            .onPressed,
        isNull);
    await tester.enterText(find.byType(TextField), '准备制作校园日常表情，使用自己的原创素材。');
    await tester.ensureVisible(find.byType(CheckboxListTile));
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('提交创作者申请'));
    await tester.tap(find.text('提交创作者申请'));
    await tester.pumpAndSettle();
    expect(find.text('申请待审核'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '制作表情包'), findsNothing);
    final requests =
        api.requests.where((request) => request.method == 'POST').toList();
    expect(requests, hasLength(1));
    expect(requests.single.path, '/emoji/creator');
    expect(requests.single.data, containsPair('rights_confirmed', true));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('创作者旧请求在切换会话后不能显示权限或提交资料', (tester) async {
    final hold = Completer<Map<String, dynamic>>();
    final api = _Api()..creatorResponse = hold.future;
    await _mount(tester, api, EmojiCreatorScreen(store: store));
    api.auth.change(id: 3);
    await tester.pump();
    hold.complete({'status': 'active', 'user_id': 3, 'version': 1});
    await tester.pumpAndSettle();
    expect(find.text('账号或权限已变化，请返回重新打开'), findsOneWidget);
    expect(find.text('制作表情包'), findsNothing);
    expect(api.requests.where((request) => request.method == 'POST'), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('创作者审核弹窗撤权后隐藏申请且不发送审批', (tester) async {
    final api = _Api();
    await _mount(tester, api, const EmojiCreatorReviewScreen());
    await tester.pumpAndSettle();
    await tester.tap(find.text('开通权限'));
    await tester.pumpAndSettle();
    expect(find.text('开通后可提交作品，每个表情包仍需单独审核。'), findsOneWidget);
    api.auth.change(id: 3, role: 'user');
    await tester.pumpAndSettle();
    expect(find.text('开通后可提交作品，每个表情包仍需单独审核。'), findsNothing);
    expect(api.requests.where((request) => request.method == 'POST'), isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('上传确认公开授权后提交；重复点击仅产生一次请求', (tester) async {
    final api = _Api();
    await _mount(
        tester,
        api,
        Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    onPressed: () => Navigator.push<void>(
                        context,
                        MaterialPageRoute(
                            builder: (_) =>
                                EmojiSubmissionUploadScreen(store: store))),
                    child: const Text('打开上传')))),
        profile: 'large');
    await tester.tap(find.text('打开上传'));
    await tester.pump();
    await waitForEmojiWork(tester);
    await tester.tap(find.text('校园日常'));
    await tester.pump();
    await waitForEmojiWork(tester);
    final submit = find.widgetWithText(FilledButton, '提交审核');
    expect(tester.widget<FilledButton>(submit).onPressed, isNull);
    final label = find.byKey(const ValueKey('emoji-label-image-1'));
    await tester.scrollUntilVisible(label, 200,
        scrollable: find.byType(Scrollable).first);
    await tester.enterText(label, '收到');
    await tester.pump();
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byType(CheckboxListTile), 200,
        scrollable: find.byType(Scrollable).first);
    await tester.ensureVisible(find.byType(Checkbox));
    await tester.pumpAndSettle();
    expect(find.byType(Checkbox).hitTestable(), findsOneWidget);
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(submit).onPressed, isNotNull);

    final hold = Completer<Object>();
    api.respond = (_) => hold.future;
    await tester.runAsync(() => tester.tap(submit));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '提交中…'));
    await tester.pump();
    // 实际文件校验和 multipart 组装走 IO，先让发送阶段完成。
    for (var i = 0;
        i < 100 && api.requests.where((r) => r.method == 'POST').isEmpty;
        i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    final requests = api.requests.where((r) => r.method == 'POST').toList();
    expect(requests, hasLength(1));
    expect(requests.single.headers['Idempotency-Key'],
        matches(RegExp(r'^[a-f0-9]{64}$')));
    expect(
        (requests.single.data as FormData).fields,
        contains(predicate<MapEntry<String, String>>((entry) =>
            entry.key == 'rights_confirmed' && entry.value == 'true')));
    expect(
        Map<String, String>.fromEntries(
            (requests.single.data as FormData).fields)['names'],
        '["收到","粘","认真","抱"]');
    hold.complete(_item());
    // 成功后还需写入／清理本机草稿；fake 时间不能驱动真实文件 IO。
    // 等路由返回再收敛动画，不能仅等 100ms 就进入 pumpAndSettle。
    for (var i = 0;
        i < 100 &&
            find.byType(EmojiSubmissionUploadScreen).evaluate().isNotEmpty;
        i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(EmojiSubmissionUploadScreen), findsNothing,
        reason: '上传与本机草稿处理必须完成并返回');
    await tester.pumpAndSettle();
    expect(find.text('打开上传'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
  });
}
