import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shenliyuan/models/post.dart';
import 'package:shenliyuan/models/publish_image_item.dart';
import 'package:shenliyuan/services/publish_image_upload_queue.dart';

void main() {
  group('每个上传状态都可以移除图片', () {
    test('waiting取消后不会发请求，也不阻塞其余图片发布', () async {
      final first = PublishImageItem.local(XFile('first.jpg'), 'first');
      final waiting = PublishImageItem.local(XFile('waiting.jpg'), 'waiting');
      final last = PublishImageItem.local(XFile('last.jpg'), 'last');
      final images = [first, waiting, last];
      final firstResponse = Completer<UploadImageResult>();
      final requested = <String>[];
      final queue = PublishImageUploadQueue(
        maxConcurrent: 1,
        isActive: images.contains,
        upload: (item, _) {
          requested.add(item.id);
          return item == first
              ? firstResponse.future
              : Future.value(const UploadImageResult.success(3));
        },
      );
      addTearDown(queue.close);
      for (final item in images) {
        queue.enqueue(item);
      }
      expect(waiting.uploadState, PublishImageUploadState.waiting);
      queue.remove(waiting);
      images.remove(waiting);
      firstResponse.complete(const UploadImageResult.success(1));

      expect(await queue.uploadAll(images), isTrue);
      expect(requested, ['first', 'last']);
      expect(waiting.fileId, isNull);
      expect(images.map((item) => item.fileId), [1, 3]);
    });

    test('uploading移除立即取消token，迟到成功不能重新加入发布', () async {
      final removed = PublishImageItem.local(XFile('uploading.jpg'), 'removed');
      final kept = PublishImageItem.local(XFile('kept.jpg'), 'kept');
      final images = [removed, kept];
      final oldResponse = Completer<UploadImageResult>();
      CancelToken? oldToken;
      final queue = PublishImageUploadQueue(
        maxConcurrent: 1,
        isActive: images.contains,
        upload: (item, token) {
          if (item == removed) {
            oldToken = token;
            return oldResponse.future;
          }
          return Future.value(const UploadImageResult.success(8));
        },
      );
      addTearDown(queue.close);
      final publishing = queue.uploadAll(images);
      expect(removed.uploadState, PublishImageUploadState.uploading);
      queue.remove(removed);
      images.remove(removed);

      expect(oldToken!.isCancelled, isTrue);
      expect(await publishing, isTrue, reason: '取消已解除发布等待，不依赖旧网络回包');
      oldResponse.complete(const UploadImageResult.success(99));
      await Future<void>.delayed(Duration.zero);
      expect(removed.fileId, isNull);
      expect(images.map((item) => item.fileId), [8]);
    });

    test('failed移除后发布其余图片，不自动重试被移除的失败项', () async {
      final failed = PublishImageItem.local(XFile('failed.jpg'), 'failed');
      final kept = PublishImageItem.local(XFile('kept.jpg'), 'kept');
      final images = [failed, kept];
      final calls = <String>[];
      final queue = PublishImageUploadQueue(
        isActive: images.contains,
        upload: (item, _) async {
          calls.add(item.id);
          return item == failed
              ? const UploadImageResult.failure(message: '网络中断')
              : const UploadImageResult.success(8);
        },
      );
      addTearDown(queue.close);
      expect(await queue.uploadAll(images), isFalse);
      expect(failed.uploadState, PublishImageUploadState.failed);
      queue.remove(failed);
      images.remove(failed);
      queue.enqueue(failed, retry: true);

      expect(await queue.uploadAll(images), isTrue);
      expect(calls, ['failed', 'kept']);
      expect(images.map((item) => item.fileId), [8]);
    });

    test('success移除只解除当前附件，file_ids排除它且共享本地源不删除', () async {
      final directory = await Directory.systemTemp.createTemp('queue-remove-');
      addTearDown(() => directory.delete(recursive: true));
      final source = File('${directory.path}/shared.jpg');
      await source.writeAsBytes([1, 2, 3, 4]);
      final removed = PublishImageItem.local(XFile(source.path), 'removed');
      final kept = PublishImageItem.local(XFile(source.path), 'kept');
      final images = [removed, kept];
      var uploads = 0;
      final queue = PublishImageUploadQueue(
        isActive: images.contains,
        upload: (item, _) async {
          uploads++;
          return UploadImageResult.success(item == removed ? 7 : 8);
        },
      );
      addTearDown(queue.close);
      expect(await queue.uploadAll(images), isTrue);
      expect(removed.uploadState, PublishImageUploadState.success);
      queue.remove(removed);
      images.remove(removed);

      expect(await queue.uploadAll(images), isTrue);
      expect(images.map((item) => item.fileId), [8]);
      expect(uploads, 2, reason: '其余成功项继续复用，不重复上传');
      expect(await source.exists(), isTrue);
      expect(await source.readAsBytes(), [1, 2, 3, 4]);
      expect(kept.localFile!.path, source.path);
    });

    test('取消后重新选择同一路径，新项不会被旧回包污染', () async {
      final old = PublishImageItem.local(XFile('same-photo.jpg'), 'old-choice');
      final replacement =
          PublishImageItem.local(XFile('same-photo.jpg'), 'new-choice');
      final images = [old];
      final replies = <String, Completer<UploadImageResult>>{};
      final tokens = <String, CancelToken>{};
      final queue = PublishImageUploadQueue(
        maxConcurrent: 1,
        isActive: images.contains,
        upload: (item, token) {
          tokens[item.id] = token;
          return (replies[item.id] = Completer<UploadImageResult>()).future;
        },
      );
      addTearDown(queue.close);
      queue.enqueue(old);
      queue.remove(old);
      images
        ..remove(old)
        ..add(replacement);
      queue.enqueue(replacement);
      expect(tokens['old-choice']!.isCancelled, isTrue);
      expect(tokens['new-choice']!.isCancelled, isFalse);
      replies['new-choice']!.complete(const UploadImageResult.success(8));
      expect(await queue.uploadAll(images), isTrue);
      replies['old-choice']!.complete(const UploadImageResult.success(99));
      await Future<void>.delayed(Duration.zero);

      expect(old.fileId, isNull);
      expect(replacement.uploadState, PublishImageUploadState.success);
      expect(images.map((item) => item.fileId), [8]);
    });
  });

  test('预上传与发布共用最多三个任务，乱序完成不改封面顺序', () async {
    final images =
        List.generate(5, (i) => PublishImageItem.local(XFile('$i.jpg'), '$i'));
    final requests = <String, Completer<UploadImageResult>>{};
    var running = 0;
    var peak = 0;
    final queue = PublishImageUploadQueue(
      isActive: images.contains,
      upload: (item, _) async {
        running++;
        if (running > peak) peak = running;
        final result =
            await (requests[item.id] = Completer<UploadImageResult>()).future;
        running--;
        return result;
      },
    );
    for (final item in images) {
      queue.enqueue(item);
      queue.enqueue(item);
    }
    final publishing = queue.uploadAll(images);
    expect(requests.keys, ['0', '1', '2']);
    requests['2']!.complete(const UploadImageResult.success(12));
    await Future<void>.delayed(Duration.zero);
    expect(requests.keys, ['0', '1', '2', '3']);
    requests['1']!.complete(const UploadImageResult.success(11));
    await Future<void>.delayed(Duration.zero);
    requests['4']!.complete(const UploadImageResult.success(14));
    requests['3']!.complete(const UploadImageResult.success(13));
    requests['0']!.complete(const UploadImageResult.success(10));
    expect(await publishing, isTrue);
    expect(images.map((e) => e.fileId), [10, 11, 12, 13, 14]);
    expect(peak, 3);
    expect(requests, hasLength(5));
  });

  test('失败可立即重试，发布不隐式重复失败或成功上传', () async {
    final item = PublishImageItem.local(XFile('photo.jpg'), 'a');
    var calls = 0;
    final queue = PublishImageUploadQueue(
      isActive: (_) => true,
      upload: (_, __) async => ++calls == 1
          ? const UploadImageResult.failure(message: '空间已满', statusCode: 429)
          : const UploadImageResult.success(9),
    );
    expect(await queue.uploadAll([item]), isFalse);
    expect(item.uploadError?.statusCode, 429);
    expect(await queue.uploadAll([item]), isFalse);
    expect(calls, 1);
    queue.enqueue(item, retry: true);
    expect(await queue.uploadAll([item]), isTrue);
    expect(item.uploadError, isNull);
    expect(calls, 2);
  });

  test('删除图片、切换会话或关闭队列后旧结果不落入表单', () async {
    for (final cancel in ['remove', 'account', 'close']) {
      final item = PublishImageItem.local(XFile('photo.jpg'), cancel);
      final next = PublishImageItem.local(XFile('next.jpg'), 'next');
      var active = true;
      final pending = Completer<UploadImageResult>();
      var calls = 0;
      final queue = PublishImageUploadQueue(
        maxConcurrent: 1,
        isActive: (_) => active,
        upload: (_, __) {
          calls++;
          return pending.future;
        },
      );
      final publishing = queue.uploadAll([item, next]);
      if (cancel == 'close') {
        queue.close();
      } else {
        active = false;
      }
      pending.complete(const UploadImageResult.success(99));
      expect(await publishing, isFalse);
      expect(item.fileId, isNull);
      expect(next.fileId, isNull);
      expect(calls, 1);
    }
  });

  test('上传抛异常时释放队列并给出可恢复失败', () async {
    final item = PublishImageItem.local(XFile('photo.jpg'), 'a');
    final queue = PublishImageUploadQueue(
      isActive: (_) => true,
      upload: (_, __) async => throw StateError('offline'),
    );
    expect(await queue.uploadAll([item]), isFalse);
    expect(item.uploadState, PublishImageUploadState.failed);
    expect(item.uploadError?.message, contains('重试'));
  });

  test('已删除的慢图不阻塞其余图片发布，并取消旧请求', () async {
    final removed = PublishImageItem.local(XFile('removed.jpg'), 'removed');
    final kept = PublishImageItem.local(XFile('kept.jpg'), 'kept');
    final images = [removed, kept];
    final slow = Completer<UploadImageResult>();
    CancelToken? removedToken;
    final queue = PublishImageUploadQueue(
      maxConcurrent: 1,
      isActive: images.contains,
      upload: (item, token) {
        if (item == removed) {
          removedToken = token;
          return slow.future;
        }
        return Future.value(const UploadImageResult.success(7));
      },
    );
    queue.enqueue(removed);
    queue.enqueue(kept);
    images.remove(removed);
    expect(await queue.uploadAll(images), isTrue);
    expect(removedToken!.isCancelled, isTrue);
    expect(kept.fileId, 7);
    slow.complete(const UploadImageResult.success(99));
    await Future<void>.delayed(Duration.zero);
    expect(removed.fileId, isNull);
    queue.close();
  });

  test('关闭队列立即取消正在上传和排队项，不等待网络返回', () async {
    final images = [
      PublishImageItem.local(XFile('first.jpg'), 'first'),
      PublishImageItem.local(XFile('next.jpg'), 'next'),
    ];
    final slow = Completer<UploadImageResult>();
    CancelToken? token;
    var calls = 0;
    final queue = PublishImageUploadQueue(
      maxConcurrent: 1,
      isActive: images.contains,
      upload: (_, currentToken) {
        calls++;
        token = currentToken;
        return slow.future;
      },
    );
    final publishing = queue.uploadAll(images);
    queue.close();
    expect(await publishing, isFalse);
    expect(token!.isCancelled, isTrue);
    expect(calls, 1);
    slow.complete(const UploadImageResult.success(99));
    await Future<void>.delayed(Duration.zero);
    expect(images.every((item) => item.fileId == null), isTrue);
  });

  test('取消后重传同一项，迟到的旧结果不能覆盖新文件', () async {
    final item = PublishImageItem.local(XFile('photo.jpg'), 'photo');
    final replies = <Completer<UploadImageResult>>[];
    final queue = PublishImageUploadQueue(
      maxConcurrent: 1,
      isActive: (_) => true,
      upload: (_, __) {
        final reply = Completer<UploadImageResult>();
        replies.add(reply);
        return reply.future;
      },
    );
    queue.enqueue(item);
    queue.remove(item);
    queue.enqueue(item, retry: true);
    expect(replies, hasLength(2));
    replies[1].complete(const UploadImageResult.success(10));
    expect(await queue.uploadAll([item]), isTrue);
    replies[0].complete(const UploadImageResult.success(99));
    await Future<void>.delayed(Duration.zero);
    expect(item.fileId, 10);
    queue.close();
  });

  test('长时间编辑后刷新临时上传，已有帖子图片始终复用', () async {
    var now = DateTime(2026, 10, 19, 12);
    final local = PublishImageItem.local(XFile('local.jpg'), 'local');
    final existing =
        PublishImageItem.existing(PostImage(id: 1, postId: 1, fileId: 80));
    var calls = 0;
    final queue = PublishImageUploadQueue(
      now: () => now,
      isActive: (_) => true,
      upload: (_, __) async => UploadImageResult.success(++calls),
    );
    expect(await queue.uploadAll([local, existing]), isTrue);
    expect(local.uploadedAt, now);
    now = now.add(const Duration(minutes: 49));
    expect(await queue.uploadAll([local, existing]), isTrue);
    expect(calls, 1);
    now = now.add(const Duration(minutes: 1));
    expect(await queue.uploadAll([local, existing]), isTrue);
    expect(calls, 2);
    expect(local.fileId, 2);
    expect(local.uploadedAt, now);
    expect(existing.fileId, 80);
    queue.close();
  });
}
