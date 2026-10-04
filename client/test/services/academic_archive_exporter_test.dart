import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/services/academic_archive_exporter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory temp;
  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    temp = await Directory.systemTemp.createTemp('academic_export_test_');
    messenger.setMockMethodCallHandler(paths, (_) async => temp.path);
  });
  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(paths, null);
    messenger.setMockMethodCallHandler(AcademicArchiveExporter.channel, null);
    await temp.delete(recursive: true);
  });
  test('公共下载成功才报告路径，并保留相同内容供分享', () async {
    messenger.setMockMethodCallHandler(AcademicArchiveExporter.channel,
        (call) async {
      expect(call.method, 'save');
      expect(call.arguments['fileName'], '课程_2026.json');
      expect(call.arguments['folder'], '课表存档');
      expect(call.arguments['content'], '[{"name":"高等数学"}]');
      return {'savedPath': 'Download/沈理校园/课表存档/课程_2026 (1).json'};
    });
    final result = await AcademicArchiveExporter.save(
        fileName: '课程/2026.json', content: '[{"name":"高等数学"}]', folder: '课表存档');
    expect(result.savedPath, 'Download/沈理校园/课表存档/课程_2026 (1).json');
    expect(await result.shareFile.readAsString(), '[{"name":"高等数学"}]');
  });
  test('公共目录写入失败不得报私有目录保存成功，随后可重试', () async {
    messenger.setMockMethodCallHandler(AcademicArchiveExporter.channel,
        (_) async {
      throw PlatformException(code: 'ARCHIVE_EXPORT_FAILED');
    });
    Future<AcademicArchiveExport> save() => AcademicArchiveExporter.save(
        fileName: '考试.json', content: '{}', folder: '考试存档');
    await expectLater(save(), throwsA(isA<PlatformException>()));
    messenger.setMockMethodCallHandler(AcademicArchiveExporter.channel,
        (_) async => {'savedPath': 'Download/沈理校园/考试存档/考试.json'});
    expect((await save()).savedPath, contains('考试存档'));
  });
  test('系统未确认公共文件写入时不能报成功', () async {
    messenger.setMockMethodCallHandler(
        AcademicArchiveExporter.channel, (_) async => {});
    await expectLater(
        AcademicArchiveExporter.save(
            fileName: '课表.json', content: '[]', folder: '课表存档'),
        throwsStateError);
  });
  test('旧版 Android 使用系统保存选择器，取消时不误报保存成功', () async {
    final picker = _LegacySavePicker();
    FilePicker.platform = picker;
    messenger.setMockMethodCallHandler(
        AcademicArchiveExporter.channel, (_) async => {'legacy': true});
    Future<AcademicArchiveExport> save() => AcademicArchiveExporter.save(
        fileName: '课表.json', content: '["数学"]', folder: '课表存档');
    await expectLater(save(), throwsStateError);
    picker.destination = '/storage/emulated/0/Download/课表.json';
    expect((await save()).savedPath, picker.destination);
    expect(utf8.decode(picker.bytes!), '["数学"]');
  });
}

class _LegacySavePicker extends FilePicker {
  String? destination;
  Uint8List? bytes;
  @override
  Future<String?> saveFile(
      {String? dialogTitle,
      String? fileName,
      String? initialDirectory,
      FileType type = FileType.any,
      List<String>? allowedExtensions,
      Uint8List? bytes,
      bool lockParentWindow = false}) async {
    this.bytes = bytes;
    return destination;
  }
}
