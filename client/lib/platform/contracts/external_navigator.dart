import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../app_platform.dart';

abstract interface class ExternalNavigator {
  Future<bool> open(Uri uri);

  factory ExternalNavigator.current() {
    if (AppPlatforms.current.isOhos) {
      return const OhosExternalNavigator();
    }
    return const AndroidExternalNavigator();
  }
}

class AndroidExternalNavigator implements ExternalNavigator {
  const AndroidExternalNavigator();

  @override
  Future<bool> open(Uri uri) async {
    if (await canLaunchUrl(uri)) {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
    return false;
  }
}

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
