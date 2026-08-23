import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/post.dart';
import 'package:shenliyuan/utils/post_clipboard.dart';

Post _post({String title = '帖子标题', String content = '帖子正文'}) {
  return Post(
    id: 1,
    title: title,
    content: content,
    boardId: 1,
    authorId: 1,
    createdAt: DateTime(2026, 8, 23),
  );
}

void main() {
  test('正文优先复制并保留正文内部换行', () {
    final text = PostClipboard.textFor(
      _post(content: '  https://example.com/download\n新版本  '),
    );

    expect(text, 'https://example.com/download\n新版本');
  });

  test('正文为空时复制标题，标题和正文都为空时返回空文本', () {
    expect(PostClipboard.textFor(_post(content: '')), '帖子标题');
    expect(PostClipboard.textFor(_post(title: '', content: '')), isEmpty);
  });

  testWidgets('复制帖子正文写入系统剪贴板', (tester) async {
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

    final copied = await PostClipboard.copy(_post(content: '下载地址'));

    expect(copied, isTrue);
    expect(copiedText, '下载地址');
  });
}
