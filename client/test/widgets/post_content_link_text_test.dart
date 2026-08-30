import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/platform/contracts/external_navigator.dart';
import 'package:shenliyuan/platform/contracts/text_boundary_resolver.dart';
import 'package:shenliyuan/widgets/post_content_link_text.dart';

Finder _postContentTextFinder(String text) {
  return find.byWidgetPredicate(
    (widget) =>
        widget is RichText && widget.text.toPlainText().contains(text) ||
        widget is EditableText && widget.controller.text.contains(text),
  );
}

class _FakeExternalNavigator implements ExternalNavigator {
  Uri? openedUri;

  @override
  Future<bool> open(Uri uri) async {
    openedUri = uri;
    return true;
  }
}

class _FakeTextBoundaryResolver implements TextBoundaryResolver {
  _FakeTextBoundaryResolver(this.future);

  final Future<TextRange?> future;
  int calls = 0;

  @override
  Future<TextRange?> resolveWordBoundary({
    required String text,
    required int offset,
  }) {
    calls++;
    return future;
  }
}

EditableTextState _editableState(WidgetTester tester) {
  return tester.state<EditableTextState>(find.byType(EditableText));
}

Future<void> _showToolbarForSelection(
  WidgetTester tester, {
  required TextSelection selection,
  SelectionChangedCause cause = SelectionChangedCause.longPress,
}) async {
  final state = _editableState(tester);
  state.userUpdateTextEditingValue(
    state.textEditingValue.copyWith(selection: selection),
    cause,
  );
  await tester.pump();
  state.showToolbar();
  await tester.pump();
}

void main() {
  test('识别 http、https 和 www 网址并去除结尾标点', () {
    final links = extractPostContentLinks(
      '访问 https://example.com/path?x=1，或 www.example.org/docs。',
    );

    expect(links.map((link) => link.text), [
      'https://example.com/path?x=1',
      'www.example.org/docs',
    ]);
    expect(links.map((link) => link.uri), [
      Uri.parse('https://example.com/path?x=1'),
      Uri.parse('https://www.example.org/docs'),
    ]);
    expect(
        extractPostContentLinks('ftp://example.com javascript://bad'), isEmpty);
  });

  testWidgets('点击网址先询问，取消时不跳转', (tester) async {
    final navigator = _FakeExternalNavigator();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PostContentLinkText(
            text: '打开 https://example.com',
            navigator: navigator,
          ),
        ),
      ),
    );

    await tester.tap(_postContentTextFinder('https://example.com'));
    await tester.pumpAndSettle();

    expect(find.text('打开网页？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(navigator.openedUri, isNull);
  });

  testWidgets('确认后通过外部导航器打开网址', (tester) async {
    final navigator = _FakeExternalNavigator();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PostContentLinkText(
            text: '打开 www.example.com',
            navigator: navigator,
          ),
        ),
      ),
    );

    await tester.tap(_postContentTextFinder('www.example.com'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(navigator.openedUri, Uri.parse('https://www.example.com'));
  });

  testWidgets('可选正文只显示应用自有四项菜单', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          platform: TargetPlatform.android,
          useMaterial3: true,
        ),
        home: const Scaffold(
          body: PostContentLinkText(
            text: '普通文字 Flutter',
            selectable: true,
          ),
        ),
      ),
    );

    await _showToolbarForSelection(
      tester,
      selection: const TextSelection(baseOffset: 0, extentOffset: 4),
    );

    expect(find.text('复制'), findsOneWidget);
    expect(find.text('搜索'), findsOneWidget);
    expect(find.text('分享'), findsOneWidget);
    expect(find.text('全选'), findsOneWidget);
    expect(find.text('Ask Claude'), findsNothing);
    expect(find.text('浏览器搜索'), findsNothing);
  });

  testWidgets('搜索动作构造百度 wd 参数并交给外部导航器', (tester) async {
    final navigator = _FakeExternalNavigator();
    const text = '沈阳理工大学';

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          platform: TargetPlatform.android,
          useMaterial3: true,
        ),
        home: Scaffold(
          body: PostContentLinkText(
            text: text,
            selectable: true,
            navigator: navigator,
          ),
        ),
      ),
    );

    await _showToolbarForSelection(
      tester,
      selection: const TextSelection(baseOffset: 0, extentOffset: 6),
    );
    await tester.tap(find.text('搜索'));
    await tester.pumpAndSettle();

    expect(
      navigator.openedUri,
      Uri.https('www.baidu.com', '/s', <String, String>{'wd': text}),
    );
  });

  testWidgets('复制结果与智能扩展后的视觉选区一致', (tester) async {
    String? copiedText;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copiedText = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    const text = '访问 https://example.com/path?q=1#reply。';
    final urlStart = text.indexOf('https://');
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          platform: TargetPlatform.android,
          useMaterial3: true,
        ),
        home: const Scaffold(
          body: PostContentLinkText(
            text: text,
            selectable: true,
          ),
        ),
      ),
    );

    await _showToolbarForSelection(
      tester,
      selection: TextSelection(
        baseOffset: urlStart + 10,
        extentOffset: urlStart + 11,
      ),
    );
    await tester.tap(find.text('复制'));
    await tester.pump();

    expect(copiedText, 'https://example.com/path?q=1#reply');
  });

  testWidgets('长按网址扩展完整链接，菜单打开链接且不自动跳转', (tester) async {
    final navigator = _FakeExternalNavigator();
    const text = '访问 https://example.com/path?q=1#reply，之后继续';
    final urlStart = text.indexOf('https://');

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          platform: TargetPlatform.android,
          useMaterial3: true,
        ),
        home: Scaffold(
          body: PostContentLinkText(
            text: text,
            selectable: true,
            navigator: navigator,
          ),
        ),
      ),
    );

    await _showToolbarForSelection(
      tester,
      selection: TextSelection(
        baseOffset: urlStart + 10,
        extentOffset: urlStart + 11,
      ),
    );

    final state = _editableState(tester);
    expect(
      state.textEditingValue.selection.textInside(text),
      'https://example.com/path?q=1#reply',
    );
    expect(find.text('复制'), findsOneWidget);
    expect(find.text('打开链接'), findsOneWidget);
    expect(find.text('分享'), findsOneWidget);
    expect(find.text('全选'), findsOneWidget);
    expect(find.text('搜索'), findsNothing);
    expect(find.text('打开网页？'), findsNothing);
    expect(navigator.openedUri, isNull);
  });

  testWidgets('拖动手柄后的选区不会被旧的智能扩展重新吸回', (tester) async {
    const text = '访问 https://example.com/path?q=1';
    final urlStart = text.indexOf('https://');

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          platform: TargetPlatform.android,
          useMaterial3: true,
        ),
        home: const Scaffold(
          body: PostContentLinkText(
            text: text,
            selectable: true,
          ),
        ),
      ),
    );

    await _showToolbarForSelection(
      tester,
      selection: TextSelection(
        baseOffset: urlStart + 10,
        extentOffset: urlStart + 11,
      ),
    );
    final state = _editableState(tester);
    expect(
      state.textEditingValue.selection.textInside(text),
      'https://example.com/path?q=1',
    );

    final draggedSelection = TextSelection(
      baseOffset: urlStart,
      extentOffset: urlStart + 4,
    );
    state.userUpdateTextEditingValue(
      state.textEditingValue.copyWith(selection: draggedSelection),
      SelectionChangedCause.drag,
    );
    await tester.pump();
    expect(state.textEditingValue.selection, draggedSelection);
  });

  testWidgets('可选正文中的网址短按仍先确认再打开', (tester) async {
    final navigator = _FakeExternalNavigator();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PostContentLinkText(
            text: '打开 https://example.com',
            selectable: true,
            navigator: navigator,
          ),
        ),
      ),
    );

    await tester.tap(_postContentTextFinder('https://example.com'));
    await tester.pumpAndSettle();

    expect(find.text('打开网页？'), findsOneWidget);
    expect(navigator.openedUri, isNull);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
  });

  testWidgets('菜单分享动作使用组件注入的分享回调', (tester) async {
    String? sharedText;

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          platform: TargetPlatform.android,
          useMaterial3: true,
        ),
        home: Scaffold(
          body: PostContentLinkText(
            text: '普通文字',
            selectable: true,
            onShare: (value) async => sharedText = value,
          ),
        ),
      ),
    );

    await _showToolbarForSelection(
      tester,
      selection: const TextSelection(baseOffset: 0, extentOffset: 4),
    );
    await tester.tap(find.text('分享'));
    await tester.pumpAndSettle();

    expect(sharedText, '普通文字');
  });

  testWidgets('中文平台边界返回前，用户拖动不会被异步结果覆盖', (tester) async {
    final boundaryCompleter = Completer<TextRange?>();
    final resolver = _FakeTextBoundaryResolver(boundaryCompleter.future);
    const text = '这是一个注册问题';

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          platform: TargetPlatform.android,
          useMaterial3: true,
        ),
        home: Scaffold(
          body: PostContentLinkText(
            text: text,
            selectable: true,
            textBoundaryResolver: resolver,
          ),
        ),
      ),
    );

    await _showToolbarForSelection(
      tester,
      selection: const TextSelection(baseOffset: 4, extentOffset: 5),
    );
    final state = _editableState(tester);
    await tester.pump();
    expect(resolver.calls, 1);
    expect(
      state.textEditingValue.selection.textInside(text),
      '注册',
    );

    final draggedSelection =
        const TextSelection(baseOffset: 4, extentOffset: 5);
    state.userUpdateTextEditingValue(
      state.textEditingValue.copyWith(selection: draggedSelection),
      SelectionChangedCause.drag,
    );
    boundaryCompleter.complete(const TextRange(start: 4, end: 6));
    await tester.pump();

    expect(state.textEditingValue.selection, draggedSelection);
  });
}
