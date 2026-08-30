import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:image_picker/image_picker.dart';
import 'package:shenliyuan/services/poll_service.dart';

void main() {
  test('投票公开图片上传使用压缩后的 JPEG 请求体', () async {
    final root = await Directory.systemTemp.createTemp('poll-upload-');
    addTearDown(() => root.delete(recursive: true));
    final file = File('${root.path}/poll.jpg');
    final source = image.fill(
      image.Image(width: 3000, height: 1200),
      color: image.ColorRgb8(32, 96, 192),
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
              data: const {'file_id': 88},
            ),
          );
        },
      ),
    );

    expect(
      await PollService(dio).uploadImages(<XFile>[XFile(file.path)]),
      <int>[88],
    );
    expect(uploadedFile, isNotNull);
    expect(uploadedFile!.length, lessThan(sourceBytes.length));
  });
}
