import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/canteen_review_draft.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/services/canteen_review_draft_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MemoryPreferencesStore store;
  late Directory tempDir;
  late CanteenReviewDraftRepository repository;

  setUp(() async {
    store = MemoryPreferencesStore();
    tempDir = await Directory.systemTemp.createTemp('canteen_draft_test_');
    repository = CanteenReviewDraftRepository(
      storeOverride: store,
      baseDirOverride: tempDir,
    );
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('保存草稿并成功恢复全部字段', () async {
    final now = DateTime.now();
    final draft = CanteenReviewDraft(
      userId: 101,
      canteenId: 1,
      star: 5,
      comment: '非常好吃，下次还来',
      tags: ['taste_good', 'portion_enough'],
      recommendedDishes: ['红烧牛肉面', '油泼面'],
      dishReviews: const [
        CanteenReviewDraftDishReview(
          dishId: 7,
          name: '红烧牛肉面',
          taste: 5,
          value: 4,
          portion: 3,
          comment: '面量足',
        ),
      ],
      images: [
        const CanteenReviewDraftImage(
          type: ReviewDraftImageType.localPending,
          localPath: '/path/to/local.jpg',
        ),
        const CanteenReviewDraftImage(
          type: ReviewDraftImageType.publishedRemote,
          url: '/uploads/published.jpg',
        ),
      ],
      updatedAt: now,
      baseRatingUpdatedAt: now.subtract(const Duration(days: 1)),
    );

    await repository.saveDraft(draft);
    final loaded = await repository.loadDraft(userId: 101, canteenId: 1);

    expect(loaded, isNotNull);
    expect(loaded!.userId, 101);
    expect(loaded.canteenId, 1);
    expect(loaded.star, 5);
    expect(loaded.comment, '非常好吃，下次还来');
    expect(loaded.tags, ['taste_good', 'portion_enough']);
    expect(loaded.recommendedDishes, ['红烧牛肉面', '油泼面']);
    expect(loaded.schemaVersion, CanteenReviewDraft.currentSchemaVersion);
    expect(loaded.dishReviews, hasLength(1));
    expect(loaded.dishReviews.single.dishId, 7);
    expect(loaded.dishReviews.single.taste, 5);
    expect(loaded.dishReviews.single.comment, '面量足');
    expect(loaded.images.length, 2);
    expect(loaded.images[0].type, ReviewDraftImageType.localPending);
    expect(loaded.images[0].localPath, '/path/to/local.jpg');
    expect(loaded.images[1].type, ReviewDraftImageType.publishedRemote);
    expect(loaded.images[1].url, '/uploads/published.jpg');
    expect(loaded.baseRatingUpdatedAt, isNotNull);
  });

  test('账号隔离：不同用户读取不到彼此的草稿', () async {
    final draftUserA = CanteenReviewDraft(
      userId: 101,
      canteenId: 1,
      star: 4,
      comment: '用户A的草稿',
      updatedAt: DateTime.now(),
    );
    await repository.saveDraft(draftUserA);

    final loadedForUserB =
        await repository.loadDraft(userId: 102, canteenId: 1);
    expect(loadedForUserB, isNull);

    final loadedForUserA =
        await repository.loadDraft(userId: 101, canteenId: 1);
    expect(loadedForUserA, isNotNull);
    expect(loadedForUserA!.comment, '用户A的草稿');
  });

  test('食堂隔离：同一用户在不同食堂具有独立草稿', () async {
    final draftCanteen1 = CanteenReviewDraft(
      userId: 101,
      canteenId: 1,
      star: 5,
      comment: '一食堂草稿',
      updatedAt: DateTime.now(),
    );
    final draftCanteen2 = CanteenReviewDraft(
      userId: 101,
      canteenId: 2,
      star: 3,
      comment: '二食堂草稿',
      updatedAt: DateTime.now(),
    );

    await repository.saveDraft(draftCanteen1);
    await repository.saveDraft(draftCanteen2);

    final loaded1 = await repository.loadDraft(userId: 101, canteenId: 1);
    final loaded2 = await repository.loadDraft(userId: 101, canteenId: 2);

    expect(loaded1!.comment, '一食堂草稿');
    expect(loaded2!.comment, '二食堂草稿');
  });

  test('保存空草稿自动触发删除', () async {
    final draft = CanteenReviewDraft(
      userId: 101,
      canteenId: 1,
      star: 5,
      comment: '初始草稿',
      updatedAt: DateTime.now(),
    );
    await repository.saveDraft(draft);
    expect(await repository.loadDraft(userId: 101, canteenId: 1), isNotNull);

    // 保存清空后的草稿
    final emptyDraft = CanteenReviewDraft(
      userId: 101,
      canteenId: 1,
      star: 0,
      comment: '',
      tags: const [],
      recommendedDishes: const [],
      images: const [],
      updatedAt: DateTime.now(),
    );
    await repository.saveDraft(emptyDraft);

    expect(await repository.loadDraft(userId: 101, canteenId: 1), isNull);
  });

  test('部分五维草稿保存后恢复时保留未填写状态，不用旧星级补齐', () async {
    await repository.saveDraft(
      CanteenReviewDraft(
        userId: 101,
        canteenId: 1,
        star: 5,
        tasteScore: 5,
        valueScore: 4,
        updatedAt: DateTime.now(),
      ),
    );
    final draft =
        await repository.loadDraft(userId: 101, canteenId: 1);

    expect(draft, isNotNull);
    final restored = draft!;
    expect(restored.tasteScore, 5);
    expect(restored.valueScore, 4);
    expect(restored.queueScore, 0);
    expect(restored.hygieneScore, 0);
    expect(restored.serviceScore, 0);
  });

  test('本地草稿图片复制与清理', () async {
    final dummyImage = File('${tempDir.path}/test_src.jpg');
    await dummyImage.writeAsString('image data');

    final copiedPath = await repository.copyImageToDraftStorage(
      userId: 101,
      canteenId: 1,
      sourcePath: dummyImage.path,
    );

    expect(File(copiedPath).existsSync(), isTrue);

    await repository.cleanupDraftImageFiles(userId: 101, canteenId: 1);
    expect(File(copiedPath).existsSync(), isFalse);
  });
}
