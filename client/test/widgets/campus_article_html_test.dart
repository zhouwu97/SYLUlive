import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/widgets/campus/campus_article_html.dart';

void main() {
  testWidgets('HTML 正文保留段落、列表和表格语义', (tester) async {
    final semanticsHandle = tester.ensureSemantics();
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: CampusArticleHtmlView(
            html: '''
              <p>一、<strong>竞赛规程</strong></p>
              <ul><li>参赛对象</li><li>赛道设置</li></ul>
              <table>
                <tr><th>项目</th><th>说明</th></tr>
                <tr><td>报名</td><td>线上提交</td></tr>
              </table>
            ''',
          ),
        ),
      ),
    );
    await tester.pump();

    final selectableText = tester
        .widgetList<SelectableText>(find.byType(SelectableText))
        .map((widget) => widget.data ?? widget.textSpan?.toPlainText() ?? '')
        .join('\n');
    expect(selectableText, contains('一、竞赛规程'));
    expect(selectableText, contains('参赛对象'));

    expect(
      find.bySemanticsLabel(RegExp('无序列表'), skipOffstage: false),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(RegExp('横向可滚动表格'), skipOffstage: false),
      findsOneWidget,
    );
    semanticsHandle.dispose();
    expect(find.byType(SingleChildScrollView), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('正文链接回调解析为 HTTPS 地址，危险图片不发起加载', (tester) async {
    String? openedUrl;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CampusArticleHtmlView(
            baseUrl: 'https://cxcyxy.sylu.edu.cn/info/1089/3317.htm',
            html: '''
              <p><a href="/info/1089/3317.htm">原文</a></p>
              <p><img src="javascript:alert(1)" alt="公告图片" /></p>
            ''',
            onOpenLink: (url) => openedUrl = url,
          ),
        ),
      ),
    );
    await tester.pump();

    final linkText = tester
        .widgetList<SelectableText>(find.byType(SelectableText))
        .firstWhere((widget) => widget.textSpan?.toPlainText() == '原文');
    final linkSpan = _findSpanWithRecognizer(linkText.textSpan!);
    expect(linkSpan?.recognizer, isA<TapGestureRecognizer>());
    (linkSpan!.recognizer! as TapGestureRecognizer).onTap!();
    expect(openedUrl, 'https://cxcyxy.sylu.edu.cn/info/1089/3317.htm');
    expect(find.text('[图片：公告图片]'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

TextSpan? _findSpanWithRecognizer(TextSpan span) {
  if (span.recognizer != null) return span;
  for (final child in span.children ?? const <InlineSpan>[]) {
    if (child is TextSpan) {
      final match = _findSpanWithRecognizer(child);
      if (match != null) return match;
    }
  }
  return null;
}
