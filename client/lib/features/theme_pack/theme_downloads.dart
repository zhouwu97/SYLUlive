import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show MethodChannel;

typedef ThemeDownloadFile = ({String name, String uri});

abstract final class ThemeDownloads {
  static const channel = MethodChannel('shenliyuan/theme_downloads');
  static const directory = 'Download/沈理校园/主题';

  static Future<List<ThemeDownloadFile>> list() async {
    if (!Platform.isAndroid) return [];
    final files = await channel.invokeListMethod<Map<Object?, Object?>>('list');
    return [
      for (final file in files ?? [])
        (name: file['name'] as String, uri: file['uri'] as String),
    ];
  }

  static Future<bool> selectDirectory() async =>
      await channel.invokeMethod<bool>('selectDirectory') ?? false;

  static Future<Uint8List> read(ThemeDownloadFile file) async =>
      (await channel.invokeMethod<Uint8List>('read', {'uri': file.uri}))!;

  static Future<bool> save(String name, Uint8List bytes) async {
    if (!Platform.isAndroid) return false;
    return await channel.invokeMethod<bool>('save', {
          'name': name,
          'bytes': bytes,
        }) ??
        false;
  }
}
