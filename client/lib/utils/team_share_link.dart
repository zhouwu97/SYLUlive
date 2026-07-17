/// 组队分享链接的统一生成与解析规则。
class TeamShareLink {
  static const String domain = 'sylulive.online';
  static const String _webScheme = 'https';
  static const String _appScheme = 'sylulive';

  static Uri webUri(int recruitmentId) {
    _validateRecruitmentId(recruitmentId);
    return Uri(
      scheme: _webScheme,
      host: domain,
      pathSegments: ['team', '$recruitmentId'],
    );
  }

  static Uri appUri(int recruitmentId) {
    _validateRecruitmentId(recruitmentId);
    return Uri(
      scheme: _appScheme,
      host: 'team',
      pathSegments: ['$recruitmentId'],
    );
  }

  /// 同时接受公开 HTTPS 链接与网页“打开 App”按钮使用的自定义协议。
  static int? parseRecruitmentId(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null) return null;

    final segments = uri.pathSegments.where((part) => part.isNotEmpty).toList();
    String? rawId;
    if (uri.scheme == _webScheme &&
        uri.host == domain &&
        segments.length == 2 &&
        segments.first == 'team') {
      rawId = segments.last;
    } else if (uri.scheme == _appScheme &&
        uri.host == 'team' &&
        segments.length == 1) {
      rawId = segments.single;
    }

    final recruitmentId = int.tryParse(rawId ?? '');
    return recruitmentId != null && recruitmentId > 0 ? recruitmentId : null;
  }

  static void _validateRecruitmentId(int recruitmentId) {
    if (recruitmentId <= 0) {
      throw ArgumentError.value(recruitmentId, 'recruitmentId', '必须为正整数');
    }
  }
}
