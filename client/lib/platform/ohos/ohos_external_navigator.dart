import 'package:flutter/services.dart';
import '../contracts/external_navigator.dart';

class OhosExternalNavigator implements ExternalNavigator {
  const OhosExternalNavigator();
  static const _channel = MethodChannel('shenliyuan/external_navigator');

  @override
  Future<bool> open(Uri uri) async {
    try {
      final res = await _channel.invokeMethod<bool>('openUrl', {'url': uri.toString()});
      return res ?? false;
    } catch (_) {
      return false;
    }
  }
}
