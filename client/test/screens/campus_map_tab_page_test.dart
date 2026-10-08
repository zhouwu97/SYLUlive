import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/screens/campus_map_tab_page.dart';

import '../helpers/golden_viewport.dart';

void main() {
  testWidgets('地图退出横屏或关闭页面后恢复系统方向策略', (tester) async {
    final calls = <List<dynamic>>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'SystemChrome.setPreferredOrientations') {
          calls.add(List<dynamic>.from(call.arguments as List));
        }
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    tester.view.devicePixelRatio = 1;
    await setGoldenViewport(tester, GoldenViewports.tabletLandscape1280x800);
    await tester.pumpWidget(const MaterialApp(home: CampusMapTabPage()));
    await tester.tap(find.byTooltip('横屏查看'));
    await tester.pump();
    expect(calls.last, [
      'DeviceOrientation.landscapeLeft',
      'DeviceOrientation.landscapeRight'
    ]);
    await tester.tap(find.byTooltip('跟随系统旋转'));
    await tester.pump();
    expect(calls.last, isEmpty);
    await tester.tap(find.byTooltip('横屏查看'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(calls.last, isEmpty);
    expect(calls.expand((value) => value),
        isNot(contains('DeviceOrientation.portraitUp')));
  });

  testWidgets('横屏请求未完成时离开地图也恢复方向且不更新已销毁页面', (tester) async {
    final pending = Completer<void>();
    final calls = <List<dynamic>>[];
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemChrome.setPreferredOrientations') {
        final values = List<dynamic>.from(call.arguments as List);
        calls.add(values);
        if (values.isNotEmpty) await pending.future;
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.pumpWidget(const MaterialApp(home: CampusMapTabPage()));
    await tester.tap(find.byTooltip('横屏查看'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(calls.last, isEmpty);
    pending.complete();
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('校园地图页面使用更新后的 PNG 地图资源', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: CampusMapTabPage()),
    );

    final image = tester.widget<Image>(find.byType(Image));
    final provider = image.image as ResizeImage;

    expect(
      provider.imageProvider,
      const AssetImage('assets/images/map.png'),
    );
  });
}
