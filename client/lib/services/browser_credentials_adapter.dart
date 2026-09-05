import 'package:dio/dio.dart';

import 'browser_credentials_adapter_stub.dart'
    if (dart.library.html) 'browser_credentials_adapter_web.dart';

void configureBrowserCredentials(Dio dio) {
  configureBrowserCredentialsImpl(dio);
}
