import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shenliyuan/providers/post_provider.dart';

void main() {
  test('uploadImage 用路径流式上传（MultipartFile.fromFile）并返回 file_id',
      () async {
    final tmpDir = await Directory.systemTemp.createTemp('upload-test-');
    final file = File('${tmpDir.path}/photo.jpg');
    await file.writeAsBytes([1, 2, 3, 4]);

    final dio = Dio();
    RequestOptions? captured;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          captured = options;
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: {'file_id': 42},
            ),
          );
        },
      ),
    );
    final provider = PostProvider(dio, enableCache: false);

    final fileId = await provider.uploadImage(XFile(file.path));
    expect(fileId, 42);
    expect(captured, isNotNull);
    expect(captured!.data, isA<FormData>());
    expect((captured!.data as FormData).files, hasLength(1));

    await tmpDir.delete(recursive: true);
  });

  test('uploadImage 失败返回 null（不抛异常）', () async {
    final tmpDir = await Directory.systemTemp.createTemp('upload-fail-');
    final file = File('${tmpDir.path}/photo.jpg');
    await file.writeAsBytes([1, 2, 3, 4]);

    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.reject(
            DioException(requestOptions: options, type: DioExceptionType.connectionError),
          );
        },
      ),
    );
    final provider = PostProvider(dio, enableCache: false);

    final fileId = await provider.uploadImage(XFile(file.path));
    expect(fileId, isNull);
    await tmpDir.delete(recursive: true);
  });
}
