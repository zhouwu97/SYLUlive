import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/services/app_update_coordinator.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/widgets/about_app_sheet.dart';
import '../helpers/golden_viewport.dart';

class _NoUpdateCoordinator extends AppUpdateCoordinator {
  @override
  Future<void> check(
      {bool force = false, bool manual = false, bool initial = false}) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    AppPreferencesStore.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: '沈理校园',
      packageName: 'com.example.shenliyuan',
      version: '1.6.6',
      buildNumber: '1606',
      buildSignature: '',
    );
  });

  for (final brightness in Brightness.values) {
    testWidgets('手动检查结果显示在关于面板上方，关闭后保留面板：$brightness', (tester) async {
      await setGoldenViewport(tester, GoldenViewports.phone360x800);
      final coordinator = _NoUpdateCoordinator();
      addTearDown(coordinator.dispose);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppUpdateCoordinator>.value(
          value: coordinator,
          child: MaterialApp(
            theme: ThemeData(brightness: brightness),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(1.3)),
              child: child!,
            ),
            home: Scaffold(
                body: Builder(
                    builder: (context) => TextButton(
                          onPressed: () => showModalBottomSheet<void>(
                            context: context,
                            isScrollControlled: true,
                            builder: (_) => const AboutAppSheet(),
                          ),
                          child: const Text('打开关于'),
                        ))),
          ),
        ),
      );
      await tester.tap(find.text('打开关于'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('检查更新'));
      await tester.tap(find.text('检查更新'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('当前已经是最新版本').hitTestable(), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('知道了'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(AboutAppSheet), findsOneWidget);
      expect(find.text('检查更新').hitTestable(), findsOneWidget);
    });
  }

  testWidgets('联系作者展示三位作者并可复制掉分员邮箱', (tester) async {
    String? copiedText;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copiedText =
              (call.arguments as Map<dynamic, dynamic>)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: AboutAppSheet()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('联系作者'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('联系作者'));
    await tester.pumpAndSettle();

    expect(find.text('纯合子'), findsOneWidget);
    expect(find.text('3170305904@qq.com'), findsOneWidget);
    expect(find.text('掉分员'), findsOneWidget);
    expect(find.text('2350016823@qq.com'), findsOneWidget);
    expect(find.text('Now'), findsOneWidget);
    expect(find.text('1517088507@qq.com'), findsOneWidget);

    await tester.tap(find.byTooltip('复制掉分员邮箱'));
    await tester.pump();

    expect(copiedText, '2350016823@qq.com');
    expect(find.text('掉分员的邮箱已复制到剪贴板'), findsOneWidget);
  });

  testWidgets('联系作者可复制 Now 邮箱', (tester) async {
    String? copiedText;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copiedText =
              (call.arguments as Map<dynamic, dynamic>)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: AboutAppSheet())),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('联系作者'));
    await tester.tap(find.text('联系作者'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('复制Now邮箱'));
    await tester.pump();

    expect(copiedText, '1517088507@qq.com');
    expect(find.text('Now的邮箱已复制到剪贴板'), findsOneWidget);
  });
}
