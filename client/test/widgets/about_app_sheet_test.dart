import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shenliyuan/widgets/about_app_sheet.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    PackageInfo.setMockInitialValues(
      appName: '沈理校园',
      packageName: 'com.example.shenliyuan',
      version: '1.6.6',
      buildNumber: '1606',
      buildSignature: '',
    );
  });

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

  testWidgets('联系作者可复制Now邮箱', (tester) async {
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

    await tester.tap(find.byTooltip('复制Now邮箱'));
    await tester.pump();

    expect(copiedText, '1517088507@qq.com');
    expect(find.text('Now的邮箱已复制到剪贴板'), findsOneWidget);
  });
}
