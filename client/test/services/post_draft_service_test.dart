import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/services/post_draft_service.dart';

void main() {
  setUp(() {
    AppPreferencesStore.setMockInitialValues({});
  });

  test('保存草稿可读回，字段完整', () async {
    final service = PostDraftService();
    await service.save(PostDraft(
      title: '标题',
      content: '正文',
      postType: 'course_study',
      waterTagId: 3,
      draftImagePaths: ['/tmp/a.jpg', '/tmp/b.jpg'],
      updatedAt: DateTime.utc(2026, 8, 10),
    ));

    final draft = await service.load();
    expect(draft, isNotNull);
    expect(draft!.title, '标题');
    expect(draft.content, '正文');
    expect(draft.postType, 'course_study');
    expect(draft.waterTagId, 3);
    expect(draft.draftImagePaths, ['/tmp/a.jpg', '/tmp/b.jpg']);
    expect(draft.updatedAt.year, 2026);
  });

  test('无草稿时 load 返回 null', () async {
    final service = PostDraftService();
    expect(await service.load(), isNull);
  });

  test('空草稿 isEmpty 为 true', () {
    expect(
      PostDraft(title: '', content: '', updatedAt: DateTime.now()).isEmpty,
      isTrue,
    );
    expect(
      PostDraft(title: '', content: 'x', updatedAt: DateTime.now()).isEmpty,
      isFalse,
    );
  });

  test('clear 删除草稿', () async {
    final service = PostDraftService();
    await service.save(
        PostDraft(title: 't', content: 'c', updatedAt: DateTime.now()));
    expect(await service.load(), isNotNull);

    await service.clear();
    expect(await service.load(), isNull);
  });
}
