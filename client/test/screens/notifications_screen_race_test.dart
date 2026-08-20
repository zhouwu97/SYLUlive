import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/screens/notifications_screen.dart';

void main() {
  test('通知刷新或首屏加载期间不会允许旧游标加载更多', () {
    bool canLoadMore({
      bool isLoading = false,
      bool isRefreshing = false,
      bool isLoadingMore = false,
      String? nextCursor = 'cursor-1',
    }) {
      return canLoadMoreNotifications(
        hasMore: true,
        isLoading: isLoading,
        isRefreshing: isRefreshing,
        isLoadingMore: isLoadingMore,
        nextCursor: nextCursor,
      );
    }

    expect(canLoadMore(), isTrue);
    expect(canLoadMore(isLoading: true), isFalse);
    expect(canLoadMore(isRefreshing: true), isFalse);
    expect(canLoadMore(isLoadingMore: true), isFalse);
    expect(canLoadMore(nextCursor: null), isFalse);
  });
}
