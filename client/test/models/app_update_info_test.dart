import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/app_update_info.dart';

void main() {
  const shaHex64 =
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

  /// 构造一个最小合法的"有更新"响应。
  Map<String, dynamic> requiredUpdateJson({
    Object? updateType = 'required',
    Object? versionCode = 1601,
    Object? latestVersionCode = 1602,
    Object? minimum = 1602,
    Object? sha256 = shaHex64,
    Object? downloadUrl = '/api/app/releases/12/download',
    Object? fileSize = 1024,
    bool updateAvailable = true,
  }) {
    return {
      'update_available': updateAvailable,
      'update_type': updateType,
      'current_version_name': '1.6.1',
      'current_version_code': versionCode,
      'latest_version_name': '1.6.2',
      'latest_version_code': latestVersionCode,
      'minimum_supported_version_code': minimum,
      'title': '沈理校园 1.6.2',
      'changelog': '修复课表拉取',
      'file_size': fileSize,
      'sha256': sha256,
      'download_url': downloadUrl,
      'published_at': '2026-07-16T10:00:00Z',
      'check_after_seconds': 21600,
    };
  }

  /// 构造一个"无更新"响应。
  Map<String, dynamic> noUpdateJson() {
    return {
      'update_available': false,
      'update_type': 'none',
      'current_version_name': '1.6.2',
      'current_version_code': 1602,
      'latest_version_name': '1.6.2',
      'latest_version_code': 1602,
      'minimum_supported_version_code': 1601,
    };
  }

  group('AppUpdateInfo.fromJson 无更新分支', () {
    test('none 类型无 update 字段缺失也可解析', () {
      final info = AppUpdateInfo.fromJson(noUpdateJson());
      expect(info.updateAvailable, isFalse);
      expect(info.updateType, AppUpdateType.none);
      expect(info.latestVersionCode, 1602);
      expect(info.currentVersionCode, 1602);
      expect(info.fileSize, 0);
      expect(info.sha256, isEmpty);
      expect(info.downloadUrl, isEmpty);
    });

    test('check_after_seconds 缺失时回退默认 21600', () {
      final json = noUpdateJson()..remove('check_after_seconds');
      final info = AppUpdateInfo.fromJson(json);
      expect(info.checkAfterSeconds, 21600);
    });

    test('published_at 缺失返回 null', () {
      final info = AppUpdateInfo.fromJson(noUpdateJson());
      expect(info.publishedAt, isNull);
    });
  });

  group('AppUpdateInfo.fromJson 有更新分支', () {
    test('required 类型正确解析所有字段并转绝对 URL', () {
      final info = AppUpdateInfo.fromJson(requiredUpdateJson());
      expect(info.updateAvailable, isTrue);
      expect(info.updateType, AppUpdateType.required);
      expect(info.latestVersionCode, 1602);
      expect(info.minimumSupportedVersionCode, 1602);
      expect(info.fileSize, 1024);
      expect(info.sha256, shaHex64);
      // ApiConstants.fullUrl 默认拼到 /api 域名后；这里只断言相对 URL 被转成
      // 包含 /api/app/releases/12/download 的绝对路径，避免依赖具体 host。
      expect(info.downloadUrl, contains('/api/app/releases/12/download'));
      expect(info.publishedAt, isNotNull);
      expect(info.publishedAt!.isUtc, isTrue);
    });

    test('optional 类型可解析', () {
      final info =
          AppUpdateInfo.fromJson(requiredUpdateJson(updateType: 'optional', minimum: 1601));
      expect(info.updateType, AppUpdateType.optional);
      expect(info.minimumSupportedVersionCode, 1601);
    });

    test('版本字段接受数字字符串', () {
      final info = AppUpdateInfo.fromJson(requiredUpdateJson(
        versionCode: '1601',
        latestVersionCode: '1602',
        minimum: '1602',
        fileSize: '2048',
      ));
      expect(info.currentVersionCode, 1601);
      expect(info.latestVersionCode, 1602);
      expect(info.minimumSupportedVersionCode, 1602);
      expect(info.fileSize, 2048);
    });

    test('绝对 download_url 透传不重复拼接', () {
      const absolute = 'https://sylulive.online/api/app/releases/12/download';
      final info = AppUpdateInfo.fromJson(requiredUpdateJson(downloadUrl: absolute));
      expect(info.downloadUrl, absolute);
    });

    test('published_at RTC 解析', () {
      final info = AppUpdateInfo.fromJson(
          requiredUpdateJson()..['published_at'] = '2026-07-16T18:00:00+08:00');
      expect(info.publishedAt, isNotNull);
    });
  });

  group('AppUpdateInfo.fromJson 严格校验拒绝', () {
    test('update_type 非法被拒绝', () {
      expect(
        () => AppUpdateInfo.fromJson(requiredUpdateJson(updateType: 'force')),
        throwsA(isA<FormatException>()),
      );
    });

    test('update_type 是 int 被拒绝', () {
      expect(
        () => AppUpdateInfo.fromJson(requiredUpdateJson(updateType: 1)),
        throwsA(isA<FormatException>()),
      );
    });

    test('latest_version_code 为 0 被拒绝', () {
      expect(
        () => AppUpdateInfo.fromJson(requiredUpdateJson(latestVersionCode: 0)),
        throwsA(isA<FormatException>()),
      );
    });

    test('latest_version_code 是非数字字符串被拒绝', () {
      expect(
        () =>
            AppUpdateInfo.fromJson(requiredUpdateJson(latestVersionCode: 'abc')),
        throwsA(isA<FormatException>()),
      );
    });

    test('minimum_supported 为负被拒绝', () {
      expect(
        () => AppUpdateInfo.fromJson(requiredUpdateJson(minimum: -1)),
        throwsA(isA<FormatException>()),
      );
    });

    test('latest_version_name 缺失被拒绝', () {
      final json = requiredUpdateJson()..remove('latest_version_name');
      expect(
        () => AppUpdateInfo.fromJson(json),
        throwsA(isA<FormatException>()),
      );
    });

    test('sha256 长度非 64 被拒绝', () {
      expect(
        () => AppUpdateInfo.fromJson(requiredUpdateJson(sha256: 'abc')),
        throwsA(isA<FormatException>()),
      );
    });

    test('sha256 含非 hex 字符被拒绝', () {
      expect(
        () => AppUpdateInfo.fromJson(
            requiredUpdateJson(sha256: 'g' * 64)),
        throwsA(isA<FormatException>()),
      );
    });

    test('sha256 缺失但有 update_available 被拒绝', () {
      final json = requiredUpdateJson()..remove('sha256');
      expect(
        () => AppUpdateInfo.fromJson(json),
        throwsA(isA<FormatException>()),
      );
    });

    test('download_url 缺失但有 update_available 被拒绝', () {
      final json = requiredUpdateJson()..remove('download_url');
      expect(
        () => AppUpdateInfo.fromJson(json),
        throwsA(isA<FormatException>()),
      );
    });

    test('file_size 为 0 但 update_available=true 被拒绝', () {
      expect(
        () => AppUpdateInfo.fromJson(requiredUpdateJson(fileSize: 0)),
        throwsA(isA<FormatException>()),
      );
    });

    test('current_version_name 缺失被拒绝', () {
      final json = noUpdateJson()..remove('current_version_name');
      expect(
        () => AppUpdateInfo.fromJson(json),
        throwsA(isA<FormatException>()),
      );
    });

    test('published_at 非法字符串被拒绝', () {
      expect(
        () => AppUpdateInfo.fromJson(
            requiredUpdateJson()..['published_at'] = 'not-a-date'),
        throwsA(isA<FormatException>()),
      );
    });

    test('current_version_code 字符串带空白也能解析', () {
      final info = AppUpdateInfo.fromJson(requiredUpdateJson(versionCode: ' 1601 '));
      expect(info.currentVersionCode, 1601);
    });
  });
}