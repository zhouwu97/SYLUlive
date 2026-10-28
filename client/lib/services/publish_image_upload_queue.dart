import 'dart:async';
import 'dart:collection';

import 'package:dio/dio.dart';

import '../models/publish_image_item.dart';

/// 选图即上传；发布和重试共用队列，避免同一图片重复上传。
class PublishImageUploadQueue {
  PublishImageUploadQueue({
    required this.upload,
    required this.isActive,
    this.onStateChanged,
    this.maxConcurrent = 3,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final Future<UploadImageResult> Function(PublishImageItem, CancelToken)
      upload;
  final bool Function(PublishImageItem) isActive;
  final void Function()? onStateChanged;
  final int maxConcurrent;
  final DateTime Function() _now;
  // 服务端可配置的临时保留期最短为 1 小时，预留十分钟应对网络等待和时钟误差。
  static const _reuseDuration = Duration(minutes: 50);
  final _waiting = Queue<_ImageUploadTask>();
  final _pending = <PublishImageItem, _ImageUploadTask>{};
  int _running = 0;
  bool _closed = false;

  void enqueue(PublishImageItem item, {bool retry = false}) {
    if (_closed ||
        !isActive(item) ||
        item.source != PublishImageSource.local ||
        _pending.containsKey(item)) {
      return;
    }
    if (item.fileId != null) {
      final uploadedAt = item.uploadedAt;
      if (uploadedAt == null ||
          _now().difference(uploadedAt) < _reuseDuration) {
        return;
      }
      item.fileId = null;
      item.uploadedAt = null;
    }
    if (!retry && item.uploadState == PublishImageUploadState.failed) return;
    item.uploadState = PublishImageUploadState.waiting;
    item.progress = 0;
    item.uploadError = null;
    final task = _ImageUploadTask(item);
    _pending[item] = task;
    _waiting.add(task);
    _drain();
  }

  Future<bool> uploadAll(List<PublishImageItem> images) async {
    for (final task in _pending.values.toList()) {
      if (!isActive(task.item) || !images.contains(task.item)) _cancel(task);
    }
    _drain();
    for (final item in images) {
      enqueue(item);
    }
    while (true) {
      final pending = images
          .where(isActive)
          .map((item) => _pending[item]?.completion.future)
          .whereType<Future<void>>()
          .toList();
      if (pending.isEmpty) break;
      await Future.wait(pending);
    }
    return !_closed && images.every((e) => isActive(e) && e.fileId != null);
  }

  void close() {
    _closed = true;
    for (final task in _pending.values.toList()) {
      _cancel(task);
    }
    _waiting.clear();
  }

  /// 删除后立即释放等待者；旧请求即使晚到，也不能覆盖同项的新任务。
  void remove(PublishImageItem item) {
    final task = _pending[item];
    if (task == null) return;
    _cancel(task);
    _drain();
  }

  void _cancel(_ImageUploadTask task) {
    task.cancelToken.cancel('图片已删除或发布页已关闭');
    _finish(task);
  }

  bool _isCurrent(_ImageUploadTask task) =>
      !_closed &&
      !task.cancelToken.isCancelled &&
      identical(_pending[task.item], task) &&
      isActive(task.item);

  void _finish(_ImageUploadTask task) {
    if (identical(_pending[task.item], task)) _pending.remove(task.item);
    if (task.started && !task.released) {
      _running--;
      task.released = true;
    }
    if (!task.completion.isCompleted) task.completion.complete();
  }

  void _drain() {
    while (_waiting.isNotEmpty && _running < maxConcurrent.clamp(1, 3)) {
      final task = _waiting.removeFirst();
      if (!_isCurrent(task)) {
        _cancel(task);
        continue;
      }
      _running++;
      task.started = true;
      unawaited(_run(task));
    }
  }

  Future<void> _run(_ImageUploadTask task) async {
    final item = task.item;
    item.uploadState = PublishImageUploadState.uploading;
    try {
      onStateChanged?.call();
      final result = await upload(item, task.cancelToken);
      if (_isCurrent(task)) {
        item.fileId = result.fileId;
        item.uploadedAt = result.isSuccess ? _now() : null;
        item.uploadError = result.isSuccess ? null : result;
        item.uploadState = result.isSuccess
            ? PublishImageUploadState.success
            : PublishImageUploadState.failed;
        if (result.isSuccess) item.progress = 1;
      }
    } catch (_) {
      if (_isCurrent(task)) {
        item.uploadState = PublishImageUploadState.failed;
        item.uploadError = const UploadImageResult.failure(
          message: '图片上传失败，请点击图片重试',
        );
      }
    } finally {
      final wasCurrent = _isCurrent(task);
      _finish(task);
      if (wasCurrent) onStateChanged?.call();
      _drain();
    }
  }
}

class _ImageUploadTask {
  _ImageUploadTask(this.item);
  final PublishImageItem item;
  final cancelToken = CancelToken();
  final completion = Completer<void>();
  bool started = false;
  bool released = false;
}
