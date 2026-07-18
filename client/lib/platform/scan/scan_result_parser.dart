/// 扫码业务协议解析结果。
sealed class ScanPayload {
  const ScanPayload();
}

class CompetitionScanPayload extends ScanPayload {
  const CompetitionScanPayload(this.eventId);

  final int eventId;
}

class ScheduleShareScanPayload extends ScanPayload {
  const ScheduleShareScanPayload(this.code);

  final String code;
}

/// 只解析应用自有协议，避免扫描普通网页或任意深链产生副作用。
class ScanResultParser {
  const ScanResultParser._();

  static ScanPayload? parse(String raw) {
    final value = raw.trim();
    if (value.isEmpty || value.length > 512) return null;
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != 'sylulive' ||
        uri.userInfo.isNotEmpty ||
        uri.port != 0 ||
        uri.query.isNotEmpty ||
        uri.fragment.isNotEmpty) {
      return null;
    }

    if (uri.host == 'competition' && uri.pathSegments.length == 1) {
      final id = int.tryParse(uri.pathSegments.single);
      if (id != null && id > 0 && id <= 2147483647) {
        return CompetitionScanPayload(id);
      }
      return null;
    }

    if (uri.host == 'schedule' &&
        uri.pathSegments.length == 2 &&
        uri.pathSegments.first == 'share') {
      final code = uri.pathSegments.last;
      if (RegExp(r'^[A-Za-z0-9_-]{6,128}$').hasMatch(code)) {
        return ScheduleShareScanPayload(code);
      }
    }
    return null;
  }
}
