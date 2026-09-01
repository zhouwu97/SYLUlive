/// 学校网络请求的固定安全策略。
///
/// 学校地址不是普通服务端配置项：调用方必须在编译期或代码中提供精确的
/// allowlist。策略拒绝明文 HTTP、非允许端口、用户信息和 IP 字面量，避免
/// 凭据因错误配置流向未知主机。
class SchoolNetworkPolicy {
  SchoolNetworkPolicy({
    required Iterable<String> personalHosts,
    Iterable<String> publicHosts = const <String>[],
    Iterable<int> allowedPorts = const <int>[443],
    this.maxRedirects = 5,
  })  : personalHosts = _normalizeHosts(personalHosts),
        publicHosts = _normalizeHosts(publicHosts),
        allowedPorts = Set<int>.unmodifiable(
          allowedPorts.where((port) => port > 0 && port <= 65535),
        ) {
    if (this.personalHosts.isEmpty && this.publicHosts.isEmpty) {
      throw ArgumentError('学校网络策略至少需要一个允许的主机');
    }
    if (this.allowedPorts.isEmpty) {
      throw ArgumentError('学校网络策略至少需要一个允许的端口');
    }
    if (maxRedirects < 0 || maxRedirects > 10) {
      throw ArgumentError.value(maxRedirects, 'maxRedirects');
    }
  }

  /// 沈阳理工学校系统的默认 allowlist。新增主机必须经过代码审计。
  factory SchoolNetworkPolicy.sylu({int maxRedirects = 5}) {
    return SchoolNetworkPolicy(
      personalHosts: const <String>[
        'jxw.sylu.edu.cn',
        'authserver.sylu.edu.cn',
        'webvpn.sylu.edu.cn',
        'xg.sylu.edu.cn',
      ],
      publicHosts: const <String>[
        'www.sylu.edu.cn',
        'sylu.edu.cn',
        'jxw.sylu.edu.cn',
      ],
      maxRedirects: maxRedirects,
    );
  }

  final Set<String> personalHosts;
  final Set<String> publicHosts;
  final Set<int> allowedPorts;
  final int maxRedirects;

  /// 验证 URL 是否可用于个人学校请求。
  Uri validatePersonal(Uri uri) => _validate(uri, personalHosts);

  /// 验证 URL 是否可用于公开学校请求。
  Uri validatePublic(Uri uri) => _validate(uri, publicHosts);

  bool isPersonalHostAllowed(String host) => _hostAllowed(host, personalHosts);

  bool isPublicHostAllowed(String host) => _hostAllowed(host, publicHosts);

  Uri _validate(Uri uri, Set<String> hosts) {
    final scheme = uri.scheme.toLowerCase();
    final host = uri.host.toLowerCase().trim();
    final port = uri.hasPort ? uri.port : 443;
    if (scheme != 'https') {
      throw const SchoolNetworkException('学校请求仅允许 HTTPS');
    }
    if (host.isEmpty || !_hostAllowed(host, hosts)) {
      throw const SchoolNetworkException('学校请求主机不在 allowlist');
    }
    if (!allowedPorts.contains(port)) {
      throw const SchoolNetworkException('学校请求端口不被允许');
    }
    if (uri.userInfo.isNotEmpty) {
      throw const SchoolNetworkException('学校请求地址禁止携带用户信息');
    }
    // 避免 DNS/代理把 IP 字面量解释成另一个学校主机。
    if (_isIpLiteral(host)) {
      throw const SchoolNetworkException('学校请求地址禁止使用 IP');
    }
    return uri;
  }

  static Set<String> _normalizeHosts(Iterable<String> values) {
    return Set<String>.unmodifiable(
      values
          .map((value) =>
              value.trim().toLowerCase().replaceFirst(RegExp(r'\.$'), ''))
          .where((value) =>
              value.isNotEmpty && !value.contains('/') && !value.contains(':')),
    );
  }

  static bool _hostAllowed(String host, Set<String> allowlist) {
    final normalized =
        host.trim().toLowerCase().replaceFirst(RegExp(r'\.$'), '');
    return allowlist.contains(normalized);
  }

  /// 不依赖 dart:io，保证 Flutter Web 与移动端共用同一策略。
  ///
  /// Uri.host 已经去掉 IPv6 方括号；这里只接受标准 IPv4/IPv6 字面量的
  /// 字符集合，并拒绝任何看起来像 IP 的主机，避免 DNS/代理绕过 allowlist。
  static bool _isIpLiteral(String host) {
    final ipv4Parts = host.split('.');
    if (ipv4Parts.length == 4 &&
        ipv4Parts.every((part) => RegExp(r'^\d{1,3}$').hasMatch(part))) {
      return ipv4Parts.every((part) => int.parse(part) <= 255);
    }
    if (!host.contains(':')) return false;
    final withoutZone = host.split('%').first;
    if (withoutZone.isEmpty ||
        !RegExp(r'^[0-9a-fA-F:]+$').hasMatch(withoutZone)) {
      return false;
    }
    final groups = withoutZone.split(':');
    if (groups.length > 8) return false;
    final compressionCount = ':'.allMatches(withoutZone).length;
    if (compressionCount > 7) return false;
    return groups.every((group) => group.isEmpty || group.length <= 4);
  }
}

/// 网络策略拒绝或学校响应无法安全处理时抛出的稳定异常。
class SchoolNetworkException implements Exception {
  const SchoolNetworkException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => 'SchoolNetworkException($message)';
}
