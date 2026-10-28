import 'package:shenliyuan/features/emoji/domain/emoji_asset_ref.dart';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:image_picker/image_picker.dart';
import 'package:shenliyuan/controllers/post_reply_composer_controller.dart';
import 'package:shenliyuan/services/post_reply_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('本地评论图片先上传并通过 file_ids 提交', () async {
    final tempDirectory = await Directory.systemTemp.createTemp(
      'post-reply-service-test-',
    );
    addTearDown(() => tempDirectory.delete(recursive: true));
    final imageFile = File('${tempDirectory.path}/reply.jpg');
    await imageFile.writeAsBytes(const [1, 2, 3, 4]);

    final dio = Dio();
    final requestPaths = <String>[];
    String? submittedFileIds;
    String? submittedAssetKey;
    String? submittedPackId;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requestPaths.add(options.path);
          if (options.path == '/upload') {
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: const {'file_id': 73},
              ),
            );
            return;
          }
          if (options.path == '/posts/8/replies') {
            final form = options.data as FormData;
            submittedAssetKey =
                Map<String, String>.fromEntries(form.fields)['asset_key'];
            submittedPackId =
                Map<String, String>.fromEntries(form.fields)['pack_id'];
            submittedFileIds =
                Map<String, String>.fromEntries(form.fields)['file_ids'];
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: {
                  'id': 9,
                  'post_id': 8,
                  'author_id': 1,
                  'content': '带图评论',
                  'created_at': DateTime(2026).toIso8601String(),
                },
              ),
            );
            return;
          }
          handler.reject(DioException(requestOptions: options));
        },
      ),
    );

    final reply = await PostReplyService(dio).submit(
      8,
      PostReplyDraft(
        text: '带图评论',
        emojiAsset:
            const EmojiAssetRef(assetKey: 'official:test:a', packId: 'test'),
        localImage: XFile(imageFile.path, name: 'reply.jpg'),
      ),
    );

    expect(requestPaths, ['/upload', '/posts/8/replies']);
    expect(submittedFileIds, '73');
    expect(submittedAssetKey, 'official:test:a');
    expect(submittedPackId, 'test');
    expect(reply.id, 9);
  });

  test('5MiB 内 JPEG 评论图片保留原始质量与字节', () async {
    final tempDirectory = await Directory.systemTemp.createTemp(
      'post-reply-compress-test-',
    );
    addTearDown(() => tempDirectory.delete(recursive: true));
    final imageFile = File('${tempDirectory.path}/reply-large.jpg');
    final source = image.fill(
      image.Image(width: 3000, height: 1200),
      color: image.ColorRgb8(50, 100, 180),
    );
    final sourceBytes = image.encodeJpg(source, quality: 95);
    await imageFile.writeAsBytes(sourceBytes);

    MultipartFile? uploadedFile;
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.path == '/upload') {
            uploadedFile = (options.data as FormData).files.single.value;
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: const {'file_id': 74},
              ),
            );
            return;
          }
          if (options.path == '/posts/8/replies') {
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: {
                  'id': 10,
                  'post_id': 8,
                  'author_id': 1,
                  'content': '压缩评论',
                  'created_at': DateTime(2026).toIso8601String(),
                },
              ),
            );
            return;
          }
          handler.reject(DioException(requestOptions: options));
        },
      ),
    );

    await PostReplyService(dio).submit(
      8,
      PostReplyDraft(
        text: '压缩评论',
        localImage: XFile(imageFile.path, name: 'reply-large.jpg'),
      ),
    );

    expect(uploadedFile, isNotNull);
    expect(uploadedFile!.length, sourceBytes.length);
    final uploadedBytes =
        await uploadedFile!.finalize().expand((chunk) => chunk).toList();
    expect(uploadedBytes, sourceBytes);
  });

  for (final format in ['png', 'gif']) {
    test('小体积 $format 评论保留格式与完整字节', () async {
      final directory = await Directory.systemTemp.createTemp('reply-$format-');
      addTearDown(() => directory.delete(recursive: true));
      final source = image.fill(image.Image(width: 24, height: 24),
          color: image.ColorRgba8(50, 100, 180, 120));
      final bytes =
          format == 'png' ? image.encodePng(source) : image.encodeGif(source);
      final file = File('${directory.path}/reply.$format');
      await file.writeAsBytes(bytes);
      MultipartFile? uploaded;
      final dio = Dio();
      dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
        if (options.path == '/upload') {
          uploaded = (options.data as FormData).files.single.value;
          handler.resolve(Response(
              requestOptions: options, statusCode: 200, data: {'file_id': 74}));
        } else {
          handler.resolve(
              Response(requestOptions: options, statusCode: 200, data: {
            'id': 10,
            'post_id': 8,
            'author_id': 1,
            'content': '图片回复',
            'created_at': DateTime(2026).toIso8601String(),
          }));
        }
      }));
      await PostReplyService(dio).submit(
          8,
          PostReplyDraft(
            text: '图片回复',
            localImage: XFile(file.path, name: 'reply.$format'),
          ));
      expect(uploaded!.contentType.toString(), 'image/$format');
      expect(uploaded!.filename, endsWith('.$format'));
      expect(
          await uploaded!.finalize().expand((chunk) => chunk).toList(), bytes);
    });
  }
}
