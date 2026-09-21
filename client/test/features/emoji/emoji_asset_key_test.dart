import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/emoji/domain/emoji_asset_key.dart';

void main() {
  test('serializes and parses namespaced keys without losing pack identity',
      () {
    const key = EmojiAssetKey(
      namespace: 'builtin',
      packId: 'mingfeng-daily',
      assetId: 'happy-001',
    );

    expect(key.serialized, 'builtin:mingfeng-daily:happy-001');
    expect(EmojiAssetKey.parse(key.serialized), key);
    expect(EmojiAssetKey.parse('unicode:😀').packId, isNull);
    expect(EmojiAssetKey.parse('private:58291').assetId, '58291');
  });

  test('rejects ambiguous or unsupported keys', () {
    for (final value in <String>[
      '',
      'unknown:asset',
      'builtin:asset-without-pack',
      'unicode:pack:asset',
      'local:pack:',
      'official:pack:a:b',
    ]) {
      expect(
        () => EmojiAssetKey.parse(value),
        throwsA(isA<FormatException>()),
        reason: value,
      );
    }
    expect(EmojiAssetKey.tryParse('not-a-key'), isNull);
  });
}
