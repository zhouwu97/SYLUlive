import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Local gravity makes the light track the device on Android; other platforms
/// use pointer light. No permission or network access is involved.
class LiquidGlassTilt extends ValueNotifier<Offset> {
  // 多个液态玻璃容器共存或横竖屏重建时复用同一广播流，保证与原生单流通道 1:1 订阅/取消。
  static final Stream<dynamic> _sharedGravityStream =
      const EventChannel('liquid_glass/gravity').receiveBroadcastStream();

  LiquidGlassTilt() : super(Offset.zero) {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      unawaited(_connect());
    }
  }

  bool _disposed = false;
  Future<void> _connect() async {
    try {
      final available = await const MethodChannel(
        'liquid_glass/capabilities',
      ).invokeMethod<bool>('gravity');
      if (_disposed || available != true) return;
      _subscription = _sharedGravityStream.listen((event) {
        if (event is List && event.length >= 2) {
          final next = Offset(
            (event[0] as num).toDouble(),
            (event[1] as num).toDouble(),
          );
          final filtered = Offset.lerp(value, next, .18)!;
          if ((filtered - value).distance > .015) value = filtered;
        }
      }, onError: (Object _) {});
    } on MissingPluginException {
      // The reusable Flutter widget also works in hosts without the sensor bridge.
    } on PlatformException {
      // Sensorless hosts retain the pointer-driven light.
    }
  }

  StreamSubscription<dynamic>? _subscription;

  @override
  void dispose() {
    _disposed = true;
    final sub = _subscription;
    _subscription = null;
    if (sub != null) {
      unawaited(sub.cancel());
    }
    super.dispose();
  }
}
