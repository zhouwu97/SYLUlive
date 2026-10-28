import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/screens/admin_teacher_governance_screen.dart';
import 'package:shenliyuan/theme/app_theme.dart';
import '../helpers/golden_viewport.dart';
import 'water_post_composer_ui_test.dart' show FakeAuthProvider;

class _Auth extends FakeAuthProvider {
  final client = Dio()..interceptors.add(InterceptorsWrapper(onRequest: (request, handler) {
    handler.resolve(Response(requestOptions: request, data: request.path == '/version'
        ? {'capabilities': {'teacher_governance_v1': true}}
        : {'groups': List.generate(24, (i) => {'id': '$i', 'course_name': '测试课程$i'})}));
  }));
  @override
  Dio get dio => client;
}

void main() {
  for (final dark in [false, true]) {
    testWidgets('治理导航在大字号和数量徽标下可滚动且无溢出 dark=$dark', (tester) async {
      await setGoldenViewport(tester, GoldenViewports.phone360x800);
      await tester.pumpWidget(ChangeNotifierProvider<AuthProvider>(
        create: (_) => _Auth(),
        child: MaterialApp(
          theme: dark ? AppTheme.darkTheme : AppTheme.lightTheme,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.3)),
            child: child!),
          home: const AdminTeacherGovernanceScreen(initialTab: 4),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('疑似推荐'), findsOneWidget);
      expect(find.text('24'), findsOneWidget);
      final tabs = tester.widget<TabBar>(find.byType(TabBar));
      expect(tabs.isScrollable, true);
      if (dark) {
        expect(tabs.labelColor, AppTheme.darkTheme.primaryColor);
      }
      await tester.ensureVisible(find.text('疑似推荐'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}
