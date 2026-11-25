import 'dart:js_interop';

import 'package:flutter/foundation.dart';

@JS('window.matchMedia')
external _MotionQuery _matchMedia(String query);

extension type _MotionQuery(JSObject _) implements JSObject {
  external bool get matches;
  external void addEventListener(String type, JSFunction listener);
  external void removeEventListener(String type, JSFunction listener);
}

// CanvasKit does not forward this browser preference on every host version.
class BrowserMotion extends ValueNotifier<bool> {
  BrowserMotion() : super(false) {
    _query = _matchMedia('(prefers-reduced-motion: reduce)');
    value = _query.matches;
    _listener = ((JSAny? _) => value = _query.matches).toJS;
    _query.addEventListener('change', _listener);
  }

  late final _MotionQuery _query;
  late final JSFunction _listener;

  @override
  void dispose() {
    _query.removeEventListener('change', _listener);
    super.dispose();
  }
}
