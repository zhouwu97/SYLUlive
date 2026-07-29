import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/conversation.dart';
import 'package:shenliyuan/models/reply.dart';

void main() {
  const stickerId = '0cc4a3688e7b222b977fef3a078619b6';

  test('message distinguishes pure and mixed sticker content', () {
    final pure = Message(
      id: 1,
      conversationId: 1,
      senderId: 1,
      content: '[表情]',
      stickerId: stickerId,
      createdAt: DateTime.utc(2026),
    );
    final mixed = Message(
      id: 2,
      conversationId: 1,
      senderId: 1,
      content: '晚安',
      stickerId: stickerId,
      createdAt: DateTime.utc(2026),
    );

    expect(pure.hasSticker, isTrue);
    expect(pure.hasTextContent, isFalse);
    expect(pure.isStickerOnly, isTrue);
    expect(pure.isMixedTextSticker, isFalse);
    expect(mixed.hasSticker, isTrue);
    expect(mixed.hasTextContent, isTrue);
    expect(mixed.isStickerOnly, isFalse);
    expect(mixed.isMixedTextSticker, isTrue);
  });

  test('reply distinguishes pure and mixed sticker content', () {
    final pure = Reply(
      id: 1,
      postId: 1,
      authorId: 1,
      content: '[表情]',
      stickerId: stickerId,
      createdAt: DateTime.utc(2026),
    );
    final mixed = Reply(
      id: 2,
      postId: 1,
      authorId: 1,
      content: '晚安',
      stickerId: stickerId,
      createdAt: DateTime.utc(2026),
    );

    expect(pure.hasTextContent, isFalse);
    expect(pure.isStickerOnly, isTrue);
    expect(mixed.hasTextContent, isTrue);
    expect(mixed.isMixedTextSticker, isTrue);
  });
}
