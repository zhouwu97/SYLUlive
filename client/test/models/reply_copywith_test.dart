import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/reply.dart';
import 'package:shenliyuan/models/user.dart';

void main() {
  Reply buildBaseReply() {
    return Reply(
      id: 1,
      postId: 42,
      parentReplyId: 7,
      authorId: 99,
      content: '原始内容',
      stickerId: 'sticker-abc',
      status: 'normal',
      likeCount: 12,
      isLiked: false,
      expEarned: 3,
      expAwards: const [],
      images: [
        ReplyImage(id: 1, replyId: 1, fileId: 100, sortOrder: 0),
      ],
      author: User(
        id: 99,
        studentId: 'S100',
        nickname: '小明',
        avatar: '',
        createdAt: DateTime(2026, 1, 1),
      ),
      createdAt: DateTime(2026, 8, 1, 12, 0),
    );
  }

  test('copyWith 只改 isLiked，其余字段完全保持', () {
    final original = buildBaseReply();
    final copy = original.copyWith(isLiked: true);

    expect(copy.isLiked, isTrue);
    expect(copy.id, original.id);
    expect(copy.postId, original.postId);
    expect(copy.parentReplyId, original.parentReplyId);
    expect(copy.authorId, original.authorId);
    expect(copy.content, original.content);
    expect(copy.stickerId, original.stickerId);
    expect(copy.status, original.status);
    expect(copy.likeCount, original.likeCount);
    expect(copy.expEarned, original.expEarned);
    expect(copy.expAwards, original.expAwards);
    expect(copy.images, original.images);
    expect(copy.author, same(original.author));
    expect(copy.createdAt, original.createdAt);
  });

  test('copyWith 只改 likeCount，其余字段保持', () {
    final original = buildBaseReply();
    final copy = original.copyWith(likeCount: 13);

    expect(copy.likeCount, 13);
    expect(copy.isLiked, original.isLiked);
    expect(copy.parentReplyId, original.parentReplyId);
    expect(copy.id, original.id);
    expect(copy.content, original.content);
  });

  test('copyWith 不改任何字段时返回等值副本', () {
    final original = buildBaseReply();
    final copy = original.copyWith();

    expect(copy.id, original.id);
    expect(copy.postId, original.postId);
    expect(copy.parentReplyId, original.parentReplyId);
    expect(copy.authorId, original.authorId);
    expect(copy.content, original.content);
    expect(copy.stickerId, original.stickerId);
    expect(copy.status, original.status);
    expect(copy.likeCount, original.likeCount);
    expect(copy.isLiked, original.isLiked);
    expect(copy.expEarned, original.expEarned);
    expect(copy.images, original.images);
    expect(copy.author, same(original.author));
    expect(copy.createdAt, original.createdAt);
  });

  test('copyWith 可同时修改多个点赞相关字段', () {
    final original = buildBaseReply();
    final copy = original.copyWith(
      likeCount: 0,
      isLiked: false,
    );
    expect(copy.likeCount, 0);
    expect(copy.isLiked, isFalse);
    expect(copy.parentReplyId, original.parentReplyId);
    expect(copy.images, original.images);
  });

  test('fromJson 解析完整字段', () {
    final reply = Reply.fromJson({
      'id': 5,
      'post_id': 42,
      'parent_reply_id': 3,
      'author_id': 8,
      'content': '你好',
      'sticker_id': 'abc',
      'status': 'normal',
      'like_count': 4,
      'is_liked': true,
      'exp_earned': 3,
      'exp_awards': <dynamic>[],
      'images': <dynamic>[],
      'author': {
        'id': 8,
        'student_id': 'S8',
        'nickname': '小新',
        'avatar': '',
        'created_at': '2026-01-01T00:00:00',
      },
      'created_at': '2026-08-01T12:00:00',
    });

    expect(reply.id, 5);
    expect(reply.postId, 42);
    expect(reply.parentReplyId, 3);
    expect(reply.authorId, 8);
    expect(reply.content, '你好');
    expect(reply.stickerId, 'abc');
    expect(reply.likeCount, 4);
    expect(reply.isLiked, isTrue);
    expect(reply.author?.nickname, '小新');
  });
}
