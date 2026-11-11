import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/academic_transfer/academic_transfer_crypto.dart';

// 与 web/src/academic-transfer.test.ts 共用的固定向量：
// 任一端改动密钥派生、附加数据或编码，两边的测试都会失败。
const _webPublic =
    'BGv4XV_oRZixDKYZnsCczX013NcZX90dx3N6DGcAbvJRuVLyXuwd7tH8oZGDiZBGY1fTFK37fpdguNmvyPOala0';
const _appPublic =
    'BAObhS22IkCKvlihjA8FZjGmykss_uwZiq4lAXytCdTo4gi2FuDcV3Wl2EB3XTja_UZ22jQQAhXovoV77SukrDA';
const _sessionId = 'AAECAwQFBgcICQoLDA0ODw';
const _plaintext =
    '{"version":1,"generatedAt":"2026-11-11T00:00:00.000Z","schedules":[{"id":"current","kind":"current","label":"测试课表","courses":[{"id":"c1","name":"高等数学","teacher":"张老师","room":"A101","day":1,"periods":[1,2],"weeks":[1,2,3]}]}]}';
const _ciphertext =
    'XyNtlS36oF8fpVvM7WGP4Lssc8fj6aXqOChBH7ZCH7yTUEFr-cteE00K9Egeqc-yFwb_8CxNAS2rSbfnL7p6MQnHxS_spwg_wXd7DLBHiKP2fL9-oLyQfF_BWs-BD8k0nI6PH0Pt7Fyqx88pksaj48RIKsdKh6cZzU0JBEEodAN1ct-y_y5YvMsnFcsYjVyBwjUwnzcOQtLSnxOAzORGIyp71arkpIdChVUnrOjPBlQUnQTxiBSfxgnj7cPPDUSurTCSfvSoEV2FkXmV9fbkfGW7W-FkHBG_cpnrYP9bM1d5xvAGGyADvD3YbQuplDzTN561nq2JhtHD-mLNHr8wlwDTFGp8lEM';

void main() {
  test('固定向量与网页端逐字节一致', () {
    final envelope = encryptAcademicTransfer(
      webPublicKey: _webPublic,
      sessionId: _sessionId,
      plaintext: utf8.encode(_plaintext),
      appPrivateKey: BigInt.parse('2e' * 32, radix: 16),
      nonce: Uint8List.fromList(List<int>.generate(12, (index) => index)),
    );
    expect(envelope.appPublicKey, _appPublic);
    expect(envelope.nonce, 'AAECAwQFBgcICQoL');
    expect(envelope.ciphertext, _ciphertext);
    expect(envelope.toJson().keys, ['app_public_key', 'nonce', 'ciphertext']);
  });

  test('每次加密都使用新的一次性密钥和随机数', () {
    final first = encryptAcademicTransfer(
      webPublicKey: _webPublic,
      sessionId: _sessionId,
      plaintext: utf8.encode('{}'),
    );
    final second = encryptAcademicTransfer(
      webPublicKey: _webPublic,
      sessionId: _sessionId,
      plaintext: utf8.encode('{}'),
    );
    expect(academicTransferDecodeBase64Url(first.appPublicKey), hasLength(65));
    expect(academicTransferDecodeBase64Url(first.nonce), hasLength(12));
    expect(first.appPublicKey, isNot(second.appPublicKey));
    expect(first.nonce, isNot(second.nonce));
  });

  test('拒绝无效公钥', () {
    for (final key in <String>[
      '',
      'not+base64',
      academicTransferBase64Url(List<int>.filled(65, 4)),
      _webPublic.substring(0, 60),
    ]) {
      expect(
        () => encryptAcademicTransfer(
            webPublicKey: key, sessionId: _sessionId, plaintext: const []),
        throwsA(isA<AcademicTransferCryptoException>()),
        reason: key,
      );
    }
  });
}
