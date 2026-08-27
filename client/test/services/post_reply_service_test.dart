import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:image_picker/image_picker.dart';
import 'package:shenliyuan/controllers/post_reply_composer_controller.dart';
import 'package:shenliyuan/services/post_reply_service.dart';

void main() {
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
        localImage: XFile(imageFile.path, name: 'reply.jpg'),
      ),
    );

    expect(requestPaths, ['/upload', '/posts/8/replies']);
    expect(submittedFileIds, '73');
    expect(reply.id, 9);
  });

  test('公开评论图片上传使用压缩后的 JPEG 请求体', () async {
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
    expect(uploadedFile!.length, lessThan(sourceBytes.length));
  });
}
