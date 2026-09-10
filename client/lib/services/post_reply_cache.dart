import 'package:dio/dio.dart';

/// 仅复用最近看过的评论首屏，按登录会话隔离，不预拉整条信息流。
class PostReplyCache {
  PostReplyCache(this._dio, {DateTime Function()? now})
      : _now = now ?? DateTime.now;

  static final _instances = Expando<PostReplyCache>();
  static PostReplyCache forClient(Dio dio) =>
      _instances[dio] ??= PostReplyCache(dio);

  final Dio _dio;
  final DateTime Function() _now;
  final _pages = <(int, String), ReplyPageSnapshot>{};
  final _requests = <(int, String), Future<Map<String, dynamic>>>{};
  String? _scope;
  int _generation = 0;

  void useScope(String scope) {
    if (_scope == scope) return;
    _scope = scope;
    invalidate();
  }

  void invalidate() {
    _generation++;
    _pages.clear();
    _requests.clear();
  }

  ReplyPageSnapshot? peek(int postId, String sort) {
    final key = (postId, sort);
    final page = _pages.remove(key);
    if (page != null) _pages[key] = page;
    return page;
  }

  Future<Map<String, dynamic>> load(int postId, String sort,
      {String? cursor, bool force = false}) {
    if (cursor != null) return _fetch(postId, sort, cursor);
    final key = (postId, sort);
    final cached = peek(postId, sort);
    if (!force &&
        cached != null &&
        _now().difference(cached.fetchedAt) < const Duration(seconds: 30)) {
      return Future.value(cached.data);
    }
    final pending = _requests[key];
    if (pending != null) return pending;
    final generation = _generation;
    late final Future<Map<String, dynamic>> request;
    request = _fetch(postId, sort, null).then((data) {
      if (_generation == generation) {
        _pages.remove(key);
        _pages[key] = ReplyPageSnapshot(data, _now());
        while (_pages.length > 20) {
          _pages.remove(_pages.keys.first);
        }
      }
      return data;
    }).whenComplete(() {
      if (identical(_requests[key], request)) _requests.remove(key);
    });
    _requests[key] = request;
    return request;
  }

  Future<Map<String, dynamic>> _fetch(
      int postId, String sort, String? cursor) async {
    final response = await _dio.get('/posts/$postId/replies', queryParameters: {
      'sort': sort,
      if (cursor != null) 'cursor': cursor,
    });
    final data = response.data;
    if (data is! Map<String, dynamic> || data['replies'] is! List) {
      throw const FormatException('评论响应格式异常');
    }
    return data;
  }
}

class ReplyPageSnapshot {
  const ReplyPageSnapshot(this.data, this.fetchedAt);
  final Map<String, dynamic> data;
  final DateTime fetchedAt;
}
