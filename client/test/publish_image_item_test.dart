import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shenliyuan/models/post.dart';
import 'package:shenliyuan/models/publish_image_item.dart';

PostImage _existing(int id, int fileId) =>
    PostImage(id: id, postId: 1, fileId: fileId);

void main() {
  test('existing factory：source、existingImage、fileId、稳定 id', () {
    final item = PublishImageItem.existing(_existing(10, 100));
    expect(item.source, PublishImageSource.existing);
    expect(item.existingImage?.id, 10);
    expect(item.localFile, isNull);
    expect(item.fileId, 100);
    expect(item.id, 'existing-10', reason: 'id 用服务器图片 id，与 index 无关');
  });

  test('local factory：source、localFile、fileId null、稳定 id', () {
    final item = PublishImageItem.local(XFile('/tmp/a.jpg'), 'local-1');
    expect(item.source, PublishImageSource.local);
    expect(item.localFile?.path, '/tmp/a.jpg');
    expect(item.existingImage, isNull);
    expect(item.fileId, isNull);
    expect(item.id, 'local-1');
  });

  group('reorderImages 语义', () {
    List<PublishImageItem> list(List<String> ids) => [
          for (final id in ids)
            PublishImageItem.local(XFile('/tmp/$id.jpg'), id),
        ];

    test('A B C 拖 A 到 C → B C A', () {
      final l = list(['A', 'B', 'C']);
      reorderImages(l, 'A', 'C');
      expect(l.map((e) => e.id).toList(), ['B', 'C', 'A']);
    });

    test('A B C 拖 C 到 A → C A B', () {
      final l = list(['A', 'B', 'C']);
      reorderImages(l, 'C', 'A');
      expect(l.map((e) => e.id).toList(), ['C', 'A', 'B']);
    });

    test('A B C 拖 A 到 B（相邻）→ B A C', () {
      final l = list(['A', 'B', 'C']);
      reorderImages(l, 'A', 'B');
      expect(l.map((e) => e.id).toList(), ['B', 'A', 'C']);
    });

    test('同项 / 未知项 → no-op', () {
      final same = list(['A', 'B', 'C']);
      reorderImages(same, 'A', 'A');
      expect(same.map((e) => e.id).toList(), ['A', 'B', 'C']);

      final unknown = list(['A', 'B', 'C']);
      reorderImages(unknown, 'Z', 'A');
      expect(unknown.map((e) => e.id).toList(), ['A', 'B', 'C']);
    });

    test('混合 existing + local 可排序（B 拖到第一位）', () {
      final images = [
        PublishImageItem.existing(_existing(1, 10)),
        PublishImageItem.local(XFile('/tmp/b.jpg'), 'local-b'),
        PublishImageItem.existing(_existing(2, 20)),
      ];
      reorderImages(images, 'local-b', 'existing-1');
      expect(images.map((e) => e.id).toList(), ['local-b', 'existing-1', 'existing-2']);
    });
  });

  test('resolveOrderedFileIds 严格按 UI 顺序（E10 L30 E20 L40 → [10,30,20,40]）',
      () async {
    final images = [
      PublishImageItem.existing(_existing(10, 10)),
      PublishImageItem.local(XFile('/tmp/x.jpg'), 'x'),
      PublishImageItem.existing(_existing(20, 20)),
      PublishImageItem.local(XFile('/tmp/y.jpg'), 'y'),
    ];
    final uploads = <String>[];
    Future<int?> upload(XFile f) async {
      uploads.add(f.path);
      return f.path.endsWith('x.jpg') ? 30 : 40;
    }

    final fileIds = await resolveOrderedFileIds(images, upload);
    expect(fileIds, [10, 30, 20, 40]);
    expect(uploads, ['/tmp/x.jpg', '/tmp/y.jpg'],
        reason: 'local 上传顺序 = UI 顺序，不能 existing 前置');
  });

  test('resolveOrderedFileIds 上传失败返回 null', () async {
    final images = [PublishImageItem.local(XFile('/tmp/x.jpg'), 'x')];
    Future<int?> fail(XFile f) async => null;
    expect(await resolveOrderedFileIds(images, fail), isNull);
  });
}
