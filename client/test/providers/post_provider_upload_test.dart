import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:image_picker/image_picker.dart';
import 'package:shenliyuan/providers/post_provider.dart';

void main() {
  test('uploadImage 用路径流式上传（MultipartFile.fromFile）并返回 file_id', () async {
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
            DioException(
                requestOptions: options,
                type: DioExceptionType.connectionError),
          );
        },
      ),
    );
    final provider = PostProvider(dio, enableCache: false);

    final fileId = await provider.uploadImage(XFile(file.path));
    expect(fileId, isNull);
    await tmpDir.delete(recursive: true);
  });

  test('uploadImage 对超出尺寸限制的公开 JPEG 上传压缩后的实际请求体', () async {
    final tmpDir = await Directory.systemTemp.createTemp('upload-compress-');
    addTearDown(() => tmpDir.delete(recursive: true));
    final file = File('${tmpDir.path}/large.jpg');
    final source = image.fill(
      image.Image(width: 3000, height: 1200),
      color: image.ColorRgb8(20, 80, 180),
    );
    final sourceBytes = image.encodeJpg(source, quality: 95);
    await file.writeAsBytes(sourceBytes);

    MultipartFile? uploadedFile;
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          uploadedFile = (options.data as FormData).files.single.value;
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: {'file_id': 43},
            ),
          );
        },
      ),
    );
    final provider = PostProvider(dio, enableCache: false);

    expect(await provider.uploadImage(XFile(file.path)), 43);
    expect(uploadedFile, isNotNull);
    expect(uploadedFile!.length, lessThan(sourceBytes.length));
  });
}
