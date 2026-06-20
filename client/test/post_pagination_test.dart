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
}
