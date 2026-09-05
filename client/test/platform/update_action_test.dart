import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/app_update_info.dart';
import 'package:shenliyuan/platform/app_installer.dart';
import 'package:shenliyuan/platform/contracts/update_action.dart';
import 'package:shenliyuan/services/app_update_download_service.dart';

void main() {
  test('更新信息变化时不会复用上一版本已下载的 APK', () async {
    final directory = await Directory.systemTemp.createTemp('update-action-');
    addTearDown(() => directory.delete(recursive: true));

    final oldBytes = utf8.encode('apk-1.6.14');
    final newBytes = utf8.encode('apk-1.6.15');
    final oldFile = File('${directory.path}/old.apk')
      ..writeAsBytesSync(oldBytes);
    final newFile = File('${directory.path}/new.apk')
      ..writeAsBytesSync(newBytes);
    final oldPackage = PreparedUpdatePackage(
      file: oldFile,
      versionCode: 1614,
      sha256: sha256.convert(oldBytes).toString(),
      fileSize: oldBytes.length,
    );
    final info = _updateInfo(
      versionCode: 1615,
      bytes: newBytes,
    );
    final installer = _FakeInstaller();
    final downloader = _FakeDownloadService(newFile);

    final result = await AndroidApkUpdateAction(installer, downloader).execute(
      info,
      existingPackage: oldPackage,
    );

    expect(result, AppUpdateActionResult.installerOpened);
    expect(downloader.calls, 1);
    expect(installer.installedFile, same(newFile));
  });
}

AppUpdateInfo _updateInfo({
  required int versionCode,
  required List<int> bytes,
}) {
  return AppUpdateInfo(
    updateAvailable: true,
    updateType: AppUpdateType.required,
    currentVersionName: '1.6.14',
    currentVersionCode: 1614,
    latestVersionName: '1.6.15',
    latestVersionCode: versionCode,
    minimumSupportedVersionCode: versionCode,
    title: '更新',
    changelog: '',
    fileSize: bytes.length,
    sha256: sha256.convert(bytes).toString(),
    downloadUrl: 'https://example.com/app.apk',
    deliveryMode: AppUpdateDeliveryMode.directPackage,
    actionUrl: '',
    publishedAt: null,
    checkAfterSeconds: 300,
  );
}

final class _FakeInstaller extends AppInstaller {
  File? installedFile;

  @override
  Future<bool> canInstallPackages() async => true;

  @override
  Future<void> installApk(File apkFile) async {
    installedFile = apkFile;
  }
}

final class _FakeDownloadService extends AppUpdateDownloadService {
  _FakeDownloadService(this.file) : super(dio: Dio());

  final File file;
  int calls = 0;

  @override
  Future<File> download({
    required String url,
    required int expectedSize,
    required String expectedSha256,
    void Function(AppDownloadProgress)? onProgress,
    CancelToken? cancelToken,
  }) async {
    calls++;
    return file;
  }
}
