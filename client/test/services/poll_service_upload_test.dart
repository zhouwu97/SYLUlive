import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:image_picker/image_picker.dart';
import 'package:shenliyuan/services/poll_service.dart';
import 'package:shenliyuan/services/publish_session_scope.dart';

void main() {
  for (final needsCompression in [false, true]) {
    test(needsCompression ? '投票大于5MiB的JPEG上传压缩后的请求体' : '投票小于5MiB的JPEG保留完整尺寸与字节',
        () async {
      final root = await Directory.systemTemp.createTemp('poll-upload-');
      addTearDown(() => root.delete(recursive: true));
      final file = File('${root.path}/poll.jpg');
      final source = image.fill(
        image.Image(width: 3000, height: 1200),
        color: image.ColorRgb8(32, 96, 192),
      );
      final sourceBytes = Uint8List.fromList([
        ...image.encodeJpg(source, quality: 95),
        if (needsCompression) ...List<int>.filled(6 * 1024 * 1024, 0),
      ]);
      await file.writeAsBytes(sourceBytes);

      MultipartFile? uploadedFile;
      Uint8List? uploadedBytes;
      Map<String, dynamic>? requestExtra;
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) async {
            uploadedFile = (options.data as FormData).files.single.value;
            final buffer = BytesBuilder(copy: false);
            await for (final chunk in uploadedFile!.finalize()) {
              buffer.add(chunk);
            }
            uploadedBytes = buffer.takeBytes();
            requestExtra = options.extra;
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
        await PollService(dio).uploadImages(
          <XFile>[XFile(file.path)],
          session: const PublishSessionScope(
            accountId: 42,
            accountSessionEpoch: 7,
          ),
        ),
        <int>[88],
      );
      expect(uploadedFile, isNotNull);
      if (needsCompression) {
        expect(uploadedFile!.length, lessThan(sourceBytes.length));
        expect(uploadedFile!.length, lessThanOrEqualTo(5 * 1024 * 1024));
      } else {
        expect(uploadedBytes, orderedEquals(sourceBytes));
      }
      final decoded = image.decodeJpg(uploadedBytes!);
      expect(decoded, isNotNull);
      expect(decoded!.width, 3000);
      expect(decoded.height, 1200);
      expect(requestExtra, containsPair('expectedAuthUserId', 42));
      expect(requestExtra, containsPair('expectedAuthSessionEpoch', 7));
    });
  }
}
