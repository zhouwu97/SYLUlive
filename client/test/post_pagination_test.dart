import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/providers/post_provider.dart';

void main() {
  test('comprehensive feed load more keeps snapshot and offset', () {
    final params = buildPostListParams(
      boardId: 1,
      sort: 'all',
      page: 2,
      loadedCount: 40,
      sessionId: 'snapshot-123',
    );

    expect(params['scene'], 'loadmore');
    expect(params['session_id'], 'snapshot-123');
    expect(params['offset'], 40);
    expect(params.containsKey('page'), isFalse);
  });

  test('latest feed load more uses normal page pagination', () {
    final params = buildPostListParams(
      boardId: 1,
      sort: 'time',
      page: 3,
      loadedCount: 40,
    );

    expect(params['page'], 3);
    expect(params.containsKey('session_id'), isFalse);
  });

  test('market type is included in the independent board state key and request',
      () {
    final params = buildPostListParams(
      boardId: 2,
      type: 'buy',
      sort: 'time',
      page: 1,
      loadedCount: 0,
    );

    expect(params['board'], 2);
    expect(params['type'], 'buy');
    expect(usesHomeFeedV2(boardId: 2, type: 'buy', sort: 'time'), isFalse);
  });

  test('版块 Topic 筛选透传 topic_id 并关闭首页 feed session', () {
    final params = buildPostListParams(
      boardId: 1,
      type: 'freshman_help',
      topicId: 42,
      sort: 'all',
      page: 1,
      loadedCount: 0,
    );

    expect(params['topic_id'], 42);
    expect(params['type'], 'freshman_help');
    expect(
      usesHomeFeedV2(
        boardId: 1,
        type: 'freshman_help',
        topicId: 42,
        sort: 'all',
      ),
      isFalse,
    );
  });
}
