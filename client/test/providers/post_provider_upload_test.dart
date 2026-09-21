import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:image_picker/image_picker.dart';
import 'package:shenliyuan/models/publish_image_item.dart';
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

    final result = await provider.uploadImage(XFile(file.path));
    expect(result.isSuccess, isTrue);
    expect(result.fileId, 42);
    expect(captured, isNotNull);
    expect(captured!.data, isA<FormData>());
    expect((captured!.data as FormData).files, hasLength(1));

    await tmpDir.delete(recursive: true);
  });

  test('uploadImage 网络失败返回结构化失败（不抛异常）', () async {
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

    final result = await provider.uploadImage(XFile(file.path));
    expect(result.isSuccess, isFalse);
    expect(result.fileId, isNull);
    expect(result.statusCode, isNull);
    expect(result.message, isNotNull);
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

    expect((await provider.uploadImage(XFile(file.path))).fileId, 43);
    expect(uploadedFile, isNotNull);
    expect(uploadedFile!.length, lessThan(sourceBytes.length));
  });

  group('uploadImage 失败映射（状态码 → 准确提示）', () {
    Future<UploadImageResult> uploadWithResponse(
      int statusCode,
      Object? body,
    ) async {
      final tmpDir = await Directory.systemTemp.createTemp('upload-map-');
      addTearDown(() => tmpDir.delete(recursive: true));
      final file = File('${tmpDir.path}/photo.jpg');
      await file.writeAsBytes([1, 2, 3, 4]);

      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            handler.reject(
              DioException(
                requestOptions: options,
                type: DioExceptionType.badResponse,
                response: Response(
                  requestOptions: options,
                  statusCode: statusCode,
                  data: body,
                ),
              ),
            );
          },
        ),
      );
      final provider = PostProvider(dio, enableCache: false);
      return provider.uploadImage(XFile(file.path));
    }

    test('429 upload_quota_exceeded 提示等待而不是重试（防重试风暴）', () async {
      final result = await uploadWithResponse(429, {
        'error': '上传频率或临时空间额度已用尽',
        'code': 'upload_quota_exceeded',
      });
      expect(result.isSuccess, isFalse);
      expect(result.fileId, isNull);
      expect(result.statusCode, 429);
      expect(result.errorCode, 'upload_quota_exceeded');
      expect(result.message, '上传过于频繁或临时空间已满，请稍后再试');
      expect(result.message, isNot(contains('重试')));
    });

    test('507 存储紧张使用服务端提示', () async {
      final result = await uploadWithResponse(507, {
        'error': '文件存储空间紧张，请稍后重试',
        'code': 'storage_capacity_exhausted',
      });
      expect(result.statusCode, 507);
      expect(result.errorCode, 'storage_capacity_exhausted');
      expect(result.message, '文件存储空间紧张，请稍后重试');
    });

    test('403 被限制上传提示切换网络', () async {
      final result = await uploadWithResponse(403, '<html>403 Forbidden</html>');
      expect(result.statusCode, 403);
      expect(result.message, '当前网络被限制上传，请切换网络后重试');
    });

    test('400 透传服务端校验提示', () async {
      final result = await uploadWithResponse(400, {'error': '只支持 jpg/png/gif 格式'});
      expect(result.statusCode, 400);
      expect(result.message, '只支持 jpg/png/gif 格式');
    });

    test('500 折叠为服务器暂不可用', () async {
      final result = await uploadWithResponse(500, {'error': '保存文件记录失败'});
      expect(result.statusCode, 500);
      expect(result.message, '服务器暂时不可用，请稍后再试');
    });
  });
}
