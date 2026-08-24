import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/platform/contracts/external_navigator.dart';
import 'package:shenliyuan/widgets/post_content_link_text.dart';

Finder _postContentTextFinder(String text) {
  return find.byWidgetPredicate(
    (widget) => widget is RichText && widget.text.toPlainText().contains(text),
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
}
