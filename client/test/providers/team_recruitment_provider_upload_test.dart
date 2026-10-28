import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:image_picker/image_picker.dart';
import 'package:shenliyuan/providers/team_recruitment_provider.dart';

void main() {
  for (final needsCompression in [false, true]) {
    test(needsCompression ? '组队大于5MiB的JPEG上传压缩后的请求体' : '组队小于5MiB的JPEG保留完整尺寸与字节',
        () async {
      final root = await Directory.systemTemp.createTemp('team-upload-');
      addTearDown(() => root.delete(recursive: true));
      final file = File('${root.path}/team.jpg');
      final source = image.fill(
        image.Image(width: 3000, height: 1200),
        color: image.ColorRgb8(40, 88, 172),
      );
      final sourceBytes = Uint8List.fromList([
        ...image.encodeJpg(source, quality: 95),
        if (needsCompression) ...List<int>.filled(6 * 1024 * 1024, 0),
      ]);
      await file.writeAsBytes(sourceBytes);

      MultipartFile? uploadedFile;
      Uint8List? uploadedBytes;
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) async {
            if (options.path == '/upload') {
              uploadedFile = (options.data as FormData).files.single.value;
              final buffer = BytesBuilder(copy: false);
              await for (final chunk in uploadedFile!.finalize()) {
                buffer.add(chunk);
              }
              uploadedBytes = buffer.takeBytes();
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: const {'file_id': 89},
                ),
              );
              return;
            }
            if (options.path == '/team/recruitments') {
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 201,
                  data: {
                    'recruitment': {
                      'id': 1,
                      'post_id': 2,
                      'category': 'study',
                      'title': '组队',
                      'description': '一起学习',
                      'author': {'id': 1, 'name': '同学'},
                      'needed_count': 3,
                      'accepted_count': 0,
                      'remaining_count': 3,
                      'status': 'recruiting',
                      'effective_status': 'recruiting',
                      'created_at': DateTime(2026).toIso8601String(),
                      'updated_at': DateTime(2026).toIso8601String(),
                    },
                  },
                ),
              );
              return;
            }
            handler.reject(DioException(requestOptions: options));
          },
        ),
      );

      final created = await TeamRecruitmentProvider(dio).create(
        category: 'study',
        title: '组队',
        description: '一起学习',
        neededCount: 3,
        roles: const ['成员'],
        images: <XFile>[XFile(file.path)],
      );

      expect(created, isNotNull);
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
    });
  }
}
