import 'package:dio/browser.dart';
import 'package:dio/dio.dart';

void configureBrowserCredentialsImpl(Dio dio) {
  dio.httpClientAdapter = BrowserHttpClientAdapter(withCredentials: true);
}
