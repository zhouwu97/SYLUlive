import 'dart:convert';

import 'package:flutter/services.dart';

import '../app_platform.dart';

/// 应用接续时只允许保存可公开的页面状态，不得写入 Token、教务密码或个人隐私。
class ContinuationState {
  const ContinuationState({
    required this.route,
    required this.competitionId,
    this.filter,
    this.noteDraft,
  });

  final String route;
  final int competitionId;
  final String? filter;
  final String? noteDraft;

  Map<String, Object?> toJson() => {
        'schemaVersion': 1,
        'route': route,
        'competitionId': competitionId,
        if (filter != null) 'filter': filter,
        if (noteDraft != null) 'noteDraft': noteDraft,
      };

  String encode() => jsonEncode(toJson());

  static ContinuationState? tryParse(String raw) {
    try {
      final value = jsonDecode(raw);
      if (value is! Map || value['schemaVersion'] != 1) return null;
      final route = value['route'];
      final id = value['competitionId'];
      if (route != 'competition_detail' || id is! num || id.toInt() <= 0) {
        return null;
      }
      return ContinuationState(
        route: route as String,
        competitionId: id.toInt(),
        filter: value['filter']?.toString(),
        noteDraft: value['noteDraft']?.toString(),
      );
    } catch (_) {
      return null;
    }
  }
}

abstract interface class ContinuationService {
  AppPlatform get platform;
  bool get isSupported;

  Future<void> save(ContinuationState state);

  Future<void> clear();

  Future<void> dispose();
}

class NoopContinuationService implements ContinuationService {
  const NoopContinuationService({required this.platform});

  @override
  final AppPlatform platform;

  @override
  bool get isSupported => false;

  @override
  Future<void> save(ContinuationState state) async {}

  @override
  Future<void> clear() async {}

  @override
  Future<void> dispose() async {}
}

class OhosContinuationService implements ContinuationService {
  OhosContinuationService({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(_channelName);

  static const _channelName = 'com.sylulive.harmony/continuation';
  final MethodChannel _channel;

  @override
  AppPlatform get platform => AppPlatform.ohos;

  @override
  bool get isSupported => true;

  @override
  Future<void> save(ContinuationState state) async {
    await _channel.invokeMethod<void>('saveState', <String, Object?>{
      'stateJson': state.encode(),
    });
  }

  @override
  Future<void> clear() async {
    await _channel.invokeMethod<void>('clearState');
  }

  @override
  Future<void> dispose() async {}
}
