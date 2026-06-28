/// Constants for the teaching evaluation assistant.
///
/// Centralizes URLs, domain allowlists, and configuration knobs.
library;

/// Root URLs for the教务 evaluation system.
class EvaluationUrls {
  EvaluationUrls._();

  /// Main evaluation index page.
  static const String evaluationIndex =
      'https://jxw.sylu.edu.cn/xspjgl/xspj_cxXspjIndex.html'
      '?gnmkdm=N401605&layout=default&dltz=yes';

  ///教务 evaluation path prefix used for script-side safety checks.
  static const String evaluationPathPrefix = '/xspjgl/';

  ///教务系统 base.
  static const String jxwBase = 'https://jxw.sylu.edu.cn';

  /// Unified authentication (CAS) domain.
  static const String casDomain = 'authserver.sylu.edu.cn';

  /// WebVPN domain.
  static const String webVpnDomain = 'webvpn.sylu.edu.cn';

  /// Real origin URLs used for cookie operations (no wildcards).
  static const List<String> cookieDomains = [
    'https://jxw.sylu.edu.cn/',
    'https://authserver.sylu.edu.cn/',
    'https://webvpn.sylu.edu.cn/',
  ];
}

/// Allowed domains for in-WebView navigation.
///
/// Any URL whose host does not match one of these patterns will be opened in
/// the system browser instead of staying inside the (possibly authenticated)
/// WebView.
class EvaluationDomainAllowlist {
  EvaluationDomainAllowlist._();

  /// Only sylu.edu.cn and its subdomains are allowed.
  /// No other university domains are included without concrete evidence.
  static final List<String> _hostSuffixes = ['sylu.edu.cn'];

  /// Returns true if [host] is allowed to load inside the evaluation WebView.
  static bool isAllowed(String host) {
    final h = host.toLowerCase().trim();
    if (h.isEmpty) return false;
    return _hostSuffixes.any((suffix) => h == suffix || h.endsWith('.$suffix'));
  }
}

/// Recognised button text / value patterns used for page detection.
class EvaluationButtonPatterns {
  EvaluationButtonPatterns._();

  static const List<String> submitPatterns = [
    '提交',
    '保存',
    '确定',
    'submit',
    'commit',
    'save',
  ];

  static const List<String> loginPatterns = ['登录', '登 录', 'sign in', 'login'];
}

/// Recognised page text patterns for session / error detection.
class EvaluationPageTextPatterns {
  EvaluationPageTextPatterns._();

  static const List<String> sessionExpired = [
    '会话已过期',
    'session expired',
    '请重新登录',
    '登录超时',
    '未登录',
    '用户未登录',
  ];

  static const List<String> accessDenied = [
    '无权限',
    '禁止访问',
    '403',
    'access denied',
    'forbidden',
  ];

  static const List<String> maintenance = ['系统维护', '正在维护', '暂未开放', '系统升级'];

  static const List<String> submitted = ['提交成功', '评价成功', '保存成功', '操作成功', '感谢'];

  static const List<String> alreadyEvaluated = ['已评价', '已完成', '已提交'];
}
