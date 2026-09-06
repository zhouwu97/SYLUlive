/// 与 Python crawler 对齐的请求头合同。
abstract final class JiaowuHeaders {
  static const userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/120.0.0.0 Safari/537.36';

  static const formContentType =
      'application/x-www-form-urlencoded;charset=utf-8';

  static const htmlAccept =
      'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8';

  static const ajaxAccept = 'application/json, text/javascript, */*; q=0.01';

  static const base = <String, String>{
    'User-Agent': userAgent,
    'Content-Type': formContentType,
    'Cache-Control': 'no-cache',
  };

  static const loginPage = <String, String>{
    ...base,
    'Accept': htmlAccept,
  };

  static const profile = <String, String>{
    ...base,
    'Accept': htmlAccept,
    'Connection': 'close',
  };

  static const menu = <String, String>{
    ...base,
    'Accept': htmlAccept,
  };

  static const course = <String, String>{
    ...base,
    'X-Requested-With': 'XMLHttpRequest',
    'Accept': ajaxAccept,
  };

  static const gradeWarmup = <String, String>{
    ...base,
    'Accept': htmlAccept,
  };

  static const grade = <String, String>{
    ...base,
    'X-Requested-With': 'XMLHttpRequest',
    'Accept': ajaxAccept,
  };
}
