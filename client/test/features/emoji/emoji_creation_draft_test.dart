import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:dio/dio.dart';
import 'package:shenliyuan/features/emoji/application/emoji_pack_importer.dart';
import 'package:shenliyuan/features/emoji/application/emoji_pack_installer.dart';
import 'package:shenliyuan/features/emoji/data/emoji_pack_local_store.dart';
import 'package:shenliyuan/features/emoji/data/emoji_submission_repository.dart';
import 'package:shenliyuan/features/emoji/domain/emoji_creation_draft.dart';
import 'package:shenliyuan/services/publish_session_scope.dart';

void main() {
  test('草稿和个人标签独立持久化，不修改安装资源；删除安装同时清理草稿和缩略图', () async {
    final root = await Directory.systemTemp.createTemp('emoji-creation-draft-');
    addTearDown(() => root.delete(recursive: true));
    final store = EmojiPackLocalStore(Directory('${root.path}/account-a'));
    final other = EmojiPackLocalStore(Directory('${root.path}/account-b'));
    final gif = image.Image(width: 8, height: 8);
    gif.addFrame(
        image.Image(width: 8, height: 8)..setPixelRgba(0, 0, 255, 0, 0, 255));
    final file =
        await File('${root.path}/快乐.gif').writeAsBytes(image.encodeGif(gif));
    final importer = EmojiPackImporter(EmojiPackInstaller(store));
    final pack =
        await importer.installPrepared(await importer.prepareImages([file]));
    final asset = pack.manifest.assets.single;
    final thumbnail = store.thumbnailFile(pack, asset);
    expect(await thumbnail.exists(), isTrue);
    expect(image.decodePng(await thumbnail.readAsBytes())!.numFrames, 1);
    expect(
        image
            .decodeGif(await File(
                    '${store.versionDirectory(pack.packId, pack.version).path}/${asset.path}')
                .readAsBytes())!
            .numFrames,
        2);
    await store.setPersonalTags(pack.packId, ['自用', '日常']);
    final draft = EmojiCreationDraft.fromPack(pack)
      ..name = '公开作品'
      ..tags = ['校园']
      ..names = {asset.id: '新的对应文字'};
    await store.saveDraft(draft);
    final reopened = EmojiPackLocalStore(store.root);
    final saved = await reopened.loadDraft(draft.key);
    expect(saved!.attemptId, draft.attemptId);
    expect(saved.names[asset.id], '新的对应文字');
    expect((await reopened.load()).single.personalTags, ['自用', '日常']);
    expect((await reopened.load()).single.manifestSha256, pack.manifestSha256);
    expect((await reopened.load()).single.manifest.assets.single.name, '快乐');
    expect(await other.loadDraft(draft.key), isNull);
    await reopened.exclusive(() async {
      final index = await reopened.readIndex();
      (index['creation_drafts'] as Map)[draft.key] = {'source_pack_id': 33};
      await reopened.writeIndex(index);
    });
    expect(await reopened.loadDraft(draft.key), isNull);
    expect((await reopened.load()).single.manifestSha256, pack.manifestSha256);
    expect((await reopened.readIndex())['creation_drafts_corrupt'],
        contains(draft.key));
    await reopened.remove(pack.packId);
    expect(await reopened.loadDraft(draft.key), isNull);
    expect(await thumbnail.exists(), isFalse);
    await expectLater(reopened.saveDraft(draft), throwsStateError);
    expect((await reopened.readIndex())['creation_drafts_corrupt'],
        isNot(contains(draft.key)));
  });

  test('重开草稿重试沿用幂等键，文字/封面等公开资料参与请求摘要', () async {
    final root =
        await Directory.systemTemp.createTemp('emoji-creation-request-');
    addTearDown(() => root.delete(recursive: true));
    final store = EmojiPackLocalStore(Directory('${root.path}/store'));
    final file = await File('${root.path}/开心.png')
        .writeAsBytes(image.encodePng(image.Image(width: 2, height: 2)));
    final importer = EmojiPackImporter(EmojiPackInstaller(store));
    final pack =
        await importer.installPrepared(await importer.prepareImages([file]));
    final draft = EmojiCreationDraft.fromPack(pack,
        revisionOf: 'community-00000000-0000-0000-0000-000000000001')
      ..tags = ['校园'];
    final keys = <String>[];
    final dio = Dio(BaseOptions(baseUrl: 'https://fixture.test/api'));
    dio.interceptors.add(InterceptorsWrapper(onRequest: (request, handler) {
      keys.add(request.headers['Idempotency-Key'] as String);
      final fields =
          Map<String, String>.fromEntries((request.data as FormData).fields);
      expect(fields['pack_id'], draft.revisionOf);
      expect(fields['cover_index'], '0');
      expect(fields['tags'], '["校园"]');
      handler.resolve(Response(requestOptions: request, statusCode: 200, data: {
        'id': 'community-fixture',
        'name': '作品',
        'status': 'pending',
        'user_id': 1,
        'asset_count': 1,
        'total_size': pack.totalSize
      }));
    }));
    const session = PublishSessionScope(accountId: 1, accountSessionEpoch: 1);
    Future<void> submit(EmojiCreationDraft value) async {
      await EmojiSubmissionRepository(dio).submit(
          pack: pack,
          store: store,
          name: value.name,
          description: value.description,
          draft: value,
          session: session,
          token: CancelToken());
    }

    await submit(draft);
    await store.saveDraft(draft);
    await submit((await store.loadDraft(draft.key))!);
    draft.names[pack.manifest.assets.single.id] = '修改后的文字';
    await submit(draft);
    expect(keys[0], keys[1]);
    expect(keys[2], isNot(keys[1]));
  });
}
