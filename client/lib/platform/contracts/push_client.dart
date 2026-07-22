import 'package:flutter/foundation.dart';

import '../app_platform.dart';

abstract interface class PushClient {
  Future<void> initialize();
  Future<String?> getRegistrationId();
  Future<bool> setPushOptIn(bool enabled);
}
