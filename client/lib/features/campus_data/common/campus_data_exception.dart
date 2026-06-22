sealed class CampusDataException implements Exception {
  final String? message;
  const CampusDataException([this.message]);

  @override
  String toString() {
    if (message != null) return '$runtimeType: $message';
    return runtimeType.toString();
  }
}

final class CampusNetworkException extends CampusDataException {
  const CampusNetworkException([super.message]);
}

final class WebVpnAccessDeniedException extends CampusDataException {
  const WebVpnAccessDeniedException([super.message]);
}

final class WebVpnSessionExpiredException extends CampusDataException {
  const WebVpnSessionExpiredException([super.message]);
}

final class CasLoginFailedException extends CampusDataException {
  const CasLoginFailedException([super.message]);
}

final class ErkeLoginFailedException extends CampusDataException {
  const ErkeLoginFailedException([super.message]);
}

final class ErkePageChangedException extends CampusDataException {
  const ErkePageChangedException([super.message]);
}

final class ErkeDecodeException extends CampusDataException {
  const ErkeDecodeException([super.message]);
}
