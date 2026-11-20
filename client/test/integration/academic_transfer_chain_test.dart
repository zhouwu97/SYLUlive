import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/academic_transfer/academic_transfer_payload.dart';
import 'package:shenliyuan/features/academic_transfer/academic_transfer_service.dart';

class _LocalHttp extends HttpOverrides {
  HttpClient client() => super.createHttpClient(null);
}

void main() {
  final origin = Platform.environment['QR_CHAIN_ORIGIN'];
  final rawLink = Platform.environment['QR_CHAIN_LINK'];
  test('真实 Flutter 请求按正确基址领取、加密上传和重试，网页公钥来自实际二维码', () async {
    final uri = Uri.parse(origin!);
    expect(uri.scheme, 'http');
    expect(uri.host, '127.0.0.1');
    final link = AcademicTransferLink.tryParse(rawLink);
    expect(link, isNotNull);
    final client = _LocalHttp().client();
    final dio = Dio(BaseOptions(baseUrl: '$origin/api'))
      ..httpClientAdapter = IOHttpClientAdapter(createHttpClient: () => client);
    addTearDown(() {
      dio.close(force: true);
      client.close(force: true);
    });
    final api = AcademicTransferApi(dio, appUserId: '7');
    await api.claim(link!.sessionId);
    final bundle = AcademicTransferBundle(schedules: [
      AcademicTransferSchedule(
          id: 'current',
          kind: 'current',
          label: '跨端合成课表',
          courses: [
            {
              'id': 'synthetic-course',
              'name': '跨端扫码课程',
              'teacher': '',
              'room': '合成教室',
              'day': DateTime.now().weekday,
              'periods': [1, 2],
              'weeks': List.generate(60, (i) => i + 1)
            },
          ]),
    ]);
    final bytes = bundle.encode({AcademicTransferPart.schedules});
    await api.upload(link, bytes);
    await api.upload(link, bytes);
  },
      skip: origin == null || rawLink == null
          ? 'Explicit loopback Web/Go/Flutter chain only'
          : false);
}
