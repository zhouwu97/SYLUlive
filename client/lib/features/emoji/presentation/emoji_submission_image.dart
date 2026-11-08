import 'dart:async';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../../../services/publish_session_scope.dart';

/// 私有预览复用认证拦截器刷新 Token，并把内存图片缓存绑定到原账号会话。
class EmojiSubmissionImage extends ImageProvider<EmojiSubmissionImage> {
  const EmojiSubmissionImage(
      {required this.dio,
      required this.url,
      required this.session,
      required this.token});
  final Dio dio;
  final String url;
  final PublishSessionScope session;
  final CancelToken token;

  @override
  Future<EmojiSubmissionImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
          EmojiSubmissionImage key, ImageDecoderCallback decode) =>
      MultiFrameImageStreamCompleter(codec: _load(key, decode), scale: 1);

  Future<ui.Codec> _load(
      EmojiSubmissionImage key, ImageDecoderCallback decode) async {
    try {
      final response = await dio.get<List<int>>(url,
          cancelToken: token,
          options: Options(
              responseType: ResponseType.bytes,
              followRedirects: false,
              extra: session.requestExtra));
      final bytes = response.data;
      if (bytes == null || bytes.isEmpty || bytes.length > 10 * 1024 * 1024) {
        throw StateError('预览图片无效或过大');
      }
      if (token.isCancelled) throw token.cancelError!;
      return await decode(
          await ui.ImmutableBuffer.fromUint8List(Uint8List.fromList(bytes)));
    } catch (_) {
      scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(key));
      rethrow;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is EmojiSubmissionImage &&
      identical(dio, other.dio) &&
      identical(token, other.token) &&
      url == other.url &&
      session.accountId == other.session.accountId &&
      session.accountSessionEpoch == other.session.accountSessionEpoch;
  @override
  int get hashCode => Object.hash(
      identityHashCode(dio),
      identityHashCode(token),
      url,
      session.accountId,
      session.accountSessionEpoch);
}
