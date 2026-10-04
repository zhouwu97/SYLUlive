import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

class AcademicArchiveExport {
  const AcademicArchiveExport(this.shareFile, this.savedPath);
  final File shareFile;
  final String savedPath;
}

/// 公共下载副本供用户找回，临时副本仅供分享，不将私有目录冒充下载目录。
class AcademicArchiveExporter {
  static const channel = MethodChannel('shenliyuan/academic_archive');

  static Future<AcademicArchiveExport> save({
    required String fileName,
    required String content,
    required String folder,
  }) async {
    final safeName = fileName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    if (!{'课表存档', '考试存档'}.contains(folder)) {
      throw ArgumentError('无效的存档目录');
    }
    final temporary = await getTemporaryDirectory();
    final shareDir =
        await Directory(path.join(temporary.path, 'academic-exports'))
            .create(recursive: true);
    final shareFile = File(path.join(
        shareDir.path, '${DateTime.now().microsecondsSinceEpoch}_$safeName'));
    await shareFile.writeAsString(content, flush: true);
    String savedPath;
    if (defaultTargetPlatform == TargetPlatform.android) {
      final result = await channel.invokeMapMethod<String, dynamic>('save', {
        'fileName': safeName,
        'content': content,
        'folder': folder,
      });
      if (result?['legacy'] == true) {
        final selected = await FilePicker.platform.saveFile(
          dialogTitle: '保存至 Download/沈理校园/$folder',
          fileName: safeName,
          bytes: Uint8List.fromList(utf8.encode(content)),
        );
        if (selected == null) throw StateError('已取消保存到下载目录');
        savedPath = selected;
      } else {
        savedPath = result?['savedPath'] as String? ?? '';
        if (savedPath.isEmpty) throw StateError('系统未确认存档已写入下载目录');
      }
    } else {
      final downloads = await getDownloadsDirectory();
      final root = downloads ?? await getApplicationDocumentsDirectory();
      final dir = Directory(path.join(root.path, '沈理校园', folder));
      await dir.create(recursive: true);
      final file = File(path.join(dir.path, safeName));
      await file.writeAsString(content, flush: true);
      savedPath = file.path;
    }
    return AcademicArchiveExport(shareFile, savedPath);
  }
}
