import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:shenliyuan/features/campus_data/storage/campus_cookie_jar.dart';

class CampusHttpSession {
  final Dio _dio;
  final CampusCookieJar _cookieJar;

  CampusHttpSession({
    Dio? dio,
    CampusCookieJar? cookieJar,
  })  : _cookieJar = cookieJar ?? CampusCookieJar(),
        _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 15),
              followRedirects: true,
              validateStatus: (status) => status != null && status < 500,
            )) {
    _dio.interceptors.add(CookieManager(_cookieJar.innerJar));
    
    // Add User-Agent matching standard browser to prevent bot blocks
    _dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      options.headers['User-Agent'] =
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
      handler.next(options);
    }));
  }

  Dio get dio => _dio;
  CampusCookieJar get cookieJar => _cookieJar;
}
