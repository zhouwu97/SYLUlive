import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/post.dart';

void main() {
  test('老帖子缺失 content_kind 时默认 normal', () {
    final post = Post.fromJson({
      'id': 1,
      'content': '旧数据',
      'board_id': 1,
      'author_id': 2,
      'created_at': '2026-07-18T12:00:00Z',
    });

    expect(post.contentKind, 'normal');
    expect(post.isPoll, isFalse);
  });

  test('content_kind 和 poll_meta 同时存在时识别为投票', () {
    final post = Post.fromJson({
      'id': 1,
      'content': '投票说明',
      'board_id': 1,
      'author_id': 2,
      'content_kind': 'poll',
      'created_at': '2026-07-18T12:00:00Z',
      'poll_meta': {
        'id': 3,
        'post_id': 1,
        'ends_at': '2026-07-20T12:00:00Z',
        'options': const [],
      },
    });

    expect(post.isPoll, isTrue);
    expect(post.pollMeta?.id, 3);
    expect(post.copyWith(content: '更新').pollMeta?.id, 3);
  });
}
