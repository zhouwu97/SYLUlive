import 'package:url_launcher/url_launcher.dart';

import '../contracts/external_navigator.dart';

class UrlLauncherExternalNavigator implements ExternalNavigator {
  const UrlLauncherExternalNavigator();

  @override
  Future<bool> open(Uri uri) async {
    if (!await canLaunchUrl(uri)) return false;
    return launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}
