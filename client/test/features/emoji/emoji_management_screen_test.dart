import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/emoji/data/emoji_pack_local_store.dart';
import 'package:shenliyuan/features/emoji/domain/emoji_pack.dart';
import 'package:shenliyuan/features/emoji/domain/emoji_pack_installation.dart';
import 'package:shenliyuan/features/emoji/domain/emoji_pack_manifest.dart';
import 'package:shenliyuan/features/emoji/presentation/emoji_management_screen.dart';
import '../../helpers/golden_viewport.dart';

class _MemoryPackStore extends EmojiPackLocalStore {
  _MemoryPackStore() : super(Directory.systemTemp);
  List<EmojiPackInstallation> items = [
    const EmojiPackInstallation(
        manifest: EmojiPackManifest(
            schemaVersion: 1,
            packId: 'pack',
            version: 1,
            totalSize: 0,
            assets: []),
        manifestSha256: 'abc',
        name: '测试表情包',
        trustLevel: EmojiPackTrustLevel.localUntrusted)
  ];
  @override
  Future<List<EmojiPackInstallation>> load() async => items;
  @override
  Future<void> setEnabled(String packId, bool enabled) async {
    items = items.map((e) => e.copyWith(enabled: enabled)).toList();
  }

  @override
  Future<void> remove(String packId) async {
    items = [];
  }
}

void main() {
  for (final dark in [false, true]) {
    testWidgets('管理页启用、删除、空状态和大字号 dark=$dark', (tester) async {
      await setGoldenViewport(tester, GoldenViewports.phone360x800);
      final store = _MemoryPackStore();
      await tester.pumpWidget(MaterialApp(
          theme: dark ? ThemeData.dark() : ThemeData.light(),
          home: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
              child: EmojiManagementScreen(store: store))));
      await tester.pumpAndSettle();
      expect(find.text('测试表情包'), findsOneWidget);
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
      await tester.tap(find.text('删除本地安装'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(find.text('暂无已安装的表情包'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
