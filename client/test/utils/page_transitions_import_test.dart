import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/utils/page_transitions.dart';

void main() {
  testWidgets('iOS 页面实际渲染 Cupertino 过渡', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(
        platform: TargetPlatform.iOS,
        pageTransitionsTheme: const PageTransitionsTheme(builders: {
          TargetPlatform.iOS: AppPageTransitionsBuilder(),
        }),
      ),
      home: Builder(
          builder: (context) => TextButton(
                onPressed: () =>
                    Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => const Scaffold(body: Text('下一页')),
                )),
                child: const Text('打开'),
              )),
    ));
    await tester.tap(find.text('打开'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(find.byType(CupertinoPageTransition), findsWidgets);
    await tester.pumpAndSettle();
    expect(find.text('下一页'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
