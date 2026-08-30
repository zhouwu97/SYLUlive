enum GatewayErrorCode {
  closed,
  accountMismatch,
  corrupted,
  unsupported,
  refreshFailed,
  eduSessionExpired,
  credentialUnavailable,
  networkUnavailable,
  localStorageFailed,
  refreshIncomplete,
  unknown,
}

/// 不携带个人字段的 Gateway 读取失败原因。
class GatewayError {
  const GatewayError(this.code, this.message);

  final GatewayErrorCode code;
  final String message;
}
