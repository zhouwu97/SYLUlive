import 'package:flutter_test/flutter_test.dart';

import 'package:jiaowu_android_probe/main.dart';

void main() {
  testWidgets('App launches smoke test', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const JiaowuProbeApp());

    // Verify that the app shows the title
    expect(find.text('教务系统 Android 验证'), findsOneWidget);
  });
}
