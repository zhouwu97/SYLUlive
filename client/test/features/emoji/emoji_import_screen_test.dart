import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/emoji/application/emoji_recent_manager.dart';
import 'package:shenliyuan/features/emoji/data/emoji_pack_local_store.dart';
import 'package:shenliyuan/features/emoji/presentation/emoji_import_screen.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/widgets/emoji/sticker_catalog.dart';
import '../../helpers/emoji_flow_qa.dart';
import '../../helpers/golden_test_app.dart';
import '../../helpers/golden_viewport.dart';

void main() {
  setUpAll(loadEmojiQAFonts);
  late Directory root;
  late EmojiPackLocalStore store;
  late EmojiRecentManager session;
  late List<File> files;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('emoji-import-screen-');
    store = EmojiPackLocalStore(Directory('${root.path}/store'));
    session = EmojiRecentManager(
        preferencesLoader: () async => MemoryPreferencesStore());
    files = [];
    for (final sticker in appStickerGroups.first.items.take(4)) {
      files.add(await File('${root.path}/${sticker.label}.png').writeAsBytes(
          (await rootBundle.load(sticker.thumbnailAsset))
              .buffer
              .asUint8List()));
    }
  });
  tearDown(() async {
    session.dispose();
    await root.delete(recursive: true);
  });

  for (final profile in ['light', 'dark', 'large', 'stress']) {
    testWidgets('导入预览真实图片与名称，360px $profile', (tester) async {
      await setGoldenViewport(tester, GoldenViewports.phone360x800);
      final capture = GlobalKey();
      await tester.pumpWidget(RepaintBoundary(
          key: capture,
          child: GoldenTestApp(
              themeMode: profile == 'dark' ? ThemeMode.dark : ThemeMode.light,
              textScaler: TextScaler.linear(profile == 'stress'
                  ? 1.5
                  : profile == 'large'
                      ? 1.3
                      : 1),
              home: EmojiImportScreen(
                  store: store,
                  recentManager: session,
                  pickImages: () async => files))));
      await tester.tap(find.text('从相册选择'));
      await tester.pump();
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      await waitForEmojiWork(tester);
      expect(find.text('导入预览'), findsOneWidget);
      expect(await tester.runAsync(store.load), isEmpty);
      expect(find.text('确认导入并使用'), findsOneWidget);
      await captureEmojiQA(tester, capture, 'import-$profile');
      await tester.enterText(find.byType(TextField), '');
      await tester.pump();
      expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
          isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('取消选择、权限失败重试与切号丢弃旧选择', (tester) async {
    var calls = 0;
    final latePick = Completer<List<File>?>();
    await tester.pumpWidget(GoldenTestApp(
        home: EmojiImportScreen(
            store: store,
            recentManager: session,
            pickImages: () async {
              calls++;
              if (calls == 1) return null;
              if (calls == 2) {
                throw PlatformException(code: 'photo_access_denied');
              }
              return latePick.future;
            })));
    await tester.tap(find.text('从相册选择'));
    await tester.pumpAndSettle();
    expect(find.text('导入预览'), findsNothing);
    await tester.tap(find.text('从相册选择'));
    await tester.pumpAndSettle();
    expect(find.textContaining('检查系统权限'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pump();
    session.switchUser('other');
    latePick.complete(files);
    await tester.pumpAndSettle();
    expect(find.textContaining('账号已切换'), findsOneWidget);
    expect(find.text('导入预览'), findsNothing);
    expect(await tester.runAsync(store.load), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('从相册选择到确认导入后返回可用 packId', (tester) async {
    String? installedId;
    await tester.pumpWidget(GoldenTestApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    onPressed: () async {
                      installedId = await Navigator.push<String>(
                          context,
                          MaterialPageRoute(
                              builder: (_) => EmojiImportScreen(
                                  store: store,
                                  recentManager: session,
                                  pickImages: () async => files)));
                    },
                    child: const Text('打开导入'))))));
    await tester.tap(find.text('打开导入'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('从相册选择'));
    await tester.pump();
    await waitForEmojiWork(tester);
    await tester.enterText(find.byType(TextField), '校园日常');
    tester.testTextInput.hide();
    await tester.pumpAndSettle();
    await tester.runAsync(() => tester.tap(find.text('确认导入并使用')));
    await tester.pump();
    await waitForEmojiWork(tester);
    expect(installedId, isNotNull);
    final packs = (await tester.runAsync(store.load))!;
    expect(packs.single.packId, installedId);
    expect(packs.single.name, '校园日常');
    expect(packs.single.enabled, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('替换文件失败后重试仍重新选文件，不会安装旧预览', (tester) async {
    var attempts = 0;
    await tester.pumpWidget(GoldenTestApp(
        home: EmojiImportScreen(
            store: store,
            recentManager: session,
            pickImages: () async => files,
            pickArchive: () async {
              attempts++;
              throw const FormatException('压缩包已损坏');
            })));
    await tester.tap(find.text('从相册选择'));
    await tester.pump();
    await waitForEmojiWork(tester);
    expect(find.text('导入预览'), findsOneWidget);
    await tester.tap(find.text('选择 ZIP / sylupack 文件'));
    await tester.pumpAndSettle();
    expect(find.text('压缩包已损坏'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(await tester.runAsync(store.load), isEmpty);
    expect(find.text('导入预览'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
