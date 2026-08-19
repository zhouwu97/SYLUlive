import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/conversation.dart';

void main() {
  test('私信附件优先解析受保护下载地址', () {
    final message = Message.fromJson({
      'id': 1,
      'conversation_id': 10,
      'sender_id': 20,
      'content': '',
      'created_at': '2026-08-11T12:00:00Z',
      'file': {
        'id': 99,
        'mime_type': 'image/jpeg',
        'size': 1024,
        'download_url': '/api/messages/files/99',
      },
    });

    expect(message.imageUrl, '/api/messages/files/99');
  });

  test('私信附件兼容旧版 path 字段', () {
    final message = Message.fromJson({
      'id': 2,
      'conversation_id': 10,
      'sender_id': 20,
      'content': '',
      'created_at': '2026-08-11T12:00:00Z',
      'file': {
        'id': 100,
        'path': '/uploads/legacy.jpg',
        'mime_type': 'image/jpeg',
      },
    });

    expect(message.imageUrl, '/uploads/legacy.jpg');
  });

  test('没有附件的私信仍返回空图片地址', () {
    final message = Message.fromJson({
      'id': 3,
      'conversation_id': 10,
      'sender_id': 20,
      'content': '文本消息',
      'created_at': '2026-08-11T12:00:00Z',
      'file': null,
    });

    expect(message.imageUrl, isEmpty);
  });
}
