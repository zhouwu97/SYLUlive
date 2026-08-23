import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/post.dart';
import 'package:shenliyuan/models/topic.dart';

void main() {
  final createdAt = DateTime.utc(2026, 8, 23);

  test('Post parses topics and keeps backward-compatible empty defaults', () {
    final post = Post.fromJson({
      'id': 7,
      'content': '话题内容',
      'board_id': 1,
      'author_id': 2,
      'created_at': createdAt.toIso8601String(),
      'topics': [
        {'id': 11, 'name': '宿舍'},
        {'id': 12, 'name': '研究生'},
      ],
    });

    expect(post.topics.map((topic) => topic.name), ['宿舍', '研究生']);
    expect(
        Post.fromJson({
          'id': 8,
          'content': '旧帖子',
          'board_id': 1,
          'author_id': 2,
          'created_at': createdAt.toIso8601String(),
        }).topics,
        isEmpty);
  });

  test('copyWith preserves topics unless explicitly replaced', () {
    final post = Post(
      id: 7,
      content: '话题内容',
      boardId: 1,
      authorId: 2,
      createdAt: createdAt,
      topics: const [Topic(id: 11, name: '宿舍')],
    );

    expect(post.copyWith(isLiked: true).topics.single.name, '宿舍');
    expect(
      post
          .copyWith(topics: const [Topic(id: 12, name: '研究生')])
          .topics
          .single
          .name,
      '研究生',
    );
  });
}
