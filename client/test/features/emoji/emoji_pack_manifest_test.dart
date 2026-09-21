import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/emoji/domain/emoji_pack_manifest.dart';

void main() {
  const sha =
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

  test('round-trips a valid manifest', () {
    const manifest = EmojiPackManifest(
      schemaVersion: 1,
      packId: 'cat-daily',
      version: 2,
      totalSize: 12,
      assets: <EmojiManifestAsset>[
        EmojiManifestAsset(
          id: 'happy-001',
          path: 'assets/happy-001.png',
          name: '开心',
          sha256: sha,
          mimeType: 'image/png',
          fileSize: 12,
          width: 64,
          height: 64,
        ),
      ],
    );

    manifest.validate();
    final decoded = EmojiPackManifest.fromJson(manifest.toJson());
    expect(decoded.packId, manifest.packId);
    expect(decoded.assets.single.path, 'assets/happy-001.png');
  });

  test('rejects duplicate ids, traversal paths and inconsistent size', () {
    Map<String, dynamic> base({
      String path = 'assets/a.png',
      int totalSize = 1,
      String id = 'a',
    }) =>
        <String, dynamic>{
          'schema_version': 1,
          'pack_id': 'safe-pack',
          'version': 1,
          'total_size': totalSize,
          'assets': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': id,
              'path': path,
              'name': 'asset',
              'sha256': sha,
              'mime_type': 'image/png',
              'file_size': 1,
            },
          ],
        };

    expect(() => EmojiPackManifest.fromJson(base(path: '../a.png')),
        throwsFormatException);
    expect(() => EmojiPackManifest.fromJson(base(totalSize: 2)),
        throwsFormatException);
    expect(
      () => EmojiPackManifest.fromJson(<String, dynamic>{
        ...base(),
        'assets': <Map<String, dynamic>>[
          ...List<Map<String, dynamic>>.from(base()['assets'] as List),
          ...List<Map<String, dynamic>>.from(base()['assets'] as List),
        ],
        'total_size': 2,
      }),
      throwsFormatException,
    );
  });
}
