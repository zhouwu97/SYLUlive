import 'package:dio/dio.dart';

import 'diagnostic_dio_factory_stub.dart'
    if (dart.library.io) 'diagnostic_dio_factory_io.dart'
    as implementation;

/// 创建网络诊断用 Dio。insecure 模式仅供 Debug Android 探针使用。
Dio createDiagnosticDio({required bool insecureTls}) {
  return implementation.createDiagnosticDio(insecureTls: insecureTls);
}
