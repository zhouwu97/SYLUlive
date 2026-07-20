/// 组队分享链接的统一生成与严格解析规则。
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

  /// 只接受固定域名、固定路径和单个正整数编号，避免把任意链接当作业务入口。
  static int? parseRecruitmentId(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null) return null;

    String? rawId;
    if (uri.scheme == _webScheme &&
        uri.host == domain &&
        uri.pathSegments.length == 2 &&
        uri.pathSegments.first == 'team' &&
        uri.queryParameters.isEmpty) {
      rawId = uri.pathSegments[1];
    } else if (uri.scheme == _appScheme &&
        uri.host == 'team' &&
        uri.pathSegments.length == 1) {
      rawId = uri.pathSegments.single;
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
