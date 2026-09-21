import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/emoji/adapters/legacy_recent_adapter.dart';

void main() {
  test('maps legacy unicode and builtin values to stable keys', () {
    final records = const LegacyRecentAdapter().adapt(<String>[
      '😀',
      'aad70d8d064f9eb79286c1393490716c',
      '😀',
    ], migratedAt: DateTime.utc(2026, 9, 20));

    expect(
      records.map((record) => record.assetKey).toList(),
      <String>[
        'unicode:😀',
        'builtin:mingfeng-daily:aad70d8d064f9eb79286c1393490716c',
      ],
    );
    expect(records.every((record) => record.useCount == 1), isTrue);
  });

  test('drops removed sticker ids instead of treating them as unicode', () {
    final records = const LegacyRecentAdapter().adapt(<String>[
      'ffffffffffffffffffffffffffffffff',
    ]);

    expect(records, isEmpty);
  });
}
