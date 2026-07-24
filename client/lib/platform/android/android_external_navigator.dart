import 'package:url_launcher/url_launcher.dart';
import '../contracts/external_navigator.dart';

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
