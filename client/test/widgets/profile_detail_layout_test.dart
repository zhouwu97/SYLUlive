import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/utils/app_navigator.dart';
import 'package:shenliyuan/widgets/profile_detail_layout.dart';

import '../helpers/golden_viewport.dart';

class _DraftPage extends StatefulWidget {
  const _DraftPage({required this.canLeave});
  final ValueNotifier<bool> canLeave;
  @override
  State<_DraftPage> createState() => _DraftPageState();
}

class _DraftPageState extends State<_DraftPage> with RouteAware {
  final controller = TextEditingController();
  int covered = 0;
  int uncovered = 0;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    appRouteObserver.subscribe(
        this, ModalRoute.of(context)! as PageRoute<dynamic>);
  }

  @override
  void didPushNext() => covered++;
  @override
  void didPopNext() => uncovered++;
  @override
  void dispose() {
    appRouteObserver.unsubscribe(this);
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
        valueListenable: widget.canLeave,
        builder: (_, value, __) => PopScope(
          canPop: value,
          child: Scaffold(
            appBar: AppBar(title: const Text('编辑页面')),
            body: ListView(children: [
              TextField(controller: controller),
              TextButton(
                  onPressed: () => Navigator.pushNamed(context, '/nested'),
                  child: const Text('继续打开')),
              TextButton(
                  onPressed: () => Navigator.pop(context, 9),
                  child: const Text('完成编辑')),
            ]),
          ),
        ),
      );
}

Future<GlobalKey<ProfileDetailLayoutState>> _show(
    WidgetTester tester, ValueNotifier<bool> canLeave) async {
  await setGoldenViewport(tester, const Size(1168, 800));
  final key = GlobalKey<ProfileDetailLayoutState>();
  await tester.pumpWidget(MaterialApp(
    routes: {
      '/nested': (_) => Scaffold(
            appBar: AppBar(title: const Text('继续打开的页面')),
          )
    },
    home: ProfileDetailLayout(
      key: key,
      navigationScope: 'account-1',
      isActive: true,
      master: const Center(child: Text('我的主页')),
    ),
  ));
  await tester.pumpAndSettle();
  return key;
}

void main() {
  testWidgets('收窄再展开保留输入、焦点和页面结果，关闭返回主栏', (tester) async {
    final canLeave = ValueNotifier(true);
    addTearDown(canLeave.dispose);
    final key = await _show(tester, canLeave);
    final future = key.currentState!.open<int>(MaterialPageRoute(
      builder: (_) => _DraftPage(canLeave: canLeave),
    ));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '保留的草稿');
    final draft = tester.state<_DraftPageState>(find.byType(_DraftPage));
    final fieldState =
        tester.state<EditableTextState>(find.byType(EditableText));
    for (final size in [const Size(600, 800), const Size(1168, 800)]) {
      await setGoldenViewport(tester, size);
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(_DraftPage)), same(draft));
      expect(draft.controller.text, '保留的草稿');
      expect(fieldState.widget.focusNode.hasFocus, isTrue);
    }
    await tester.tap(find.text('完成编辑'));
    await tester.pumpAndSettle();
    expect(await future, 9);
    expect(find.byType(_DraftPage), findsNothing);
    expect(find.text('我的主页'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('左侧切换遵守详情离开限制，取消后继续保留草稿', (tester) async {
    final canLeave = ValueNotifier(false);
    addTearDown(canLeave.dispose);
    final key = await _show(tester, canLeave);
    key.currentState!.open(MaterialPageRoute(
      builder: (_) => _DraftPage(canLeave: canLeave),
    ));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '尚未保存');
    await key.currentState!.open(MaterialPageRoute(
      builder: (_) => const Scaffold(body: Text('其他入口')),
    ));
    await tester.pumpAndSettle();
    expect(find.text('尚未保存'), findsOneWidget);
    expect(find.text('其他入口'), findsNothing);
    canLeave.value = true;
    await tester.pumpAndSettle();
    final next = key.currentState!.open(MaterialPageRoute(
      builder: (_) => Scaffold(appBar: AppBar(title: const Text('其他入口'))),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(_DraftPage), findsNothing);
    expect(find.text('其他入口'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await next;
    expect(find.text('选择左侧功能查看详情'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('命名子路由沿用应用路由表，并正确通知页面遮挡和返回', (tester) async {
    final canLeave = ValueNotifier(true);
    addTearDown(canLeave.dispose);
    final key = await _show(tester, canLeave);
    key.currentState!.open(MaterialPageRoute(
      builder: (_) => _DraftPage(canLeave: canLeave),
    ));
    await tester.pumpAndSettle();
    final draft = tester.state<_DraftPageState>(find.byType(_DraftPage));
    await tester.tap(find.text('继续打开'));
    await tester.pumpAndSettle();
    expect(find.text('我的主页'), findsOneWidget);
    expect(find.text('继续打开的页面'), findsOneWidget);
    expect(draft.covered, 1);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(draft.uncovered, 1);
    expect(find.byType(_DraftPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
