import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/utils/campus_article_image.dart';
import 'package:shenliyuan/utils/image_decode_size.dart';

void main() {
  test('本站上传图片按目标尺寸返回分层候选，并保留查询参数', () {
    final resources = CampusArticleImageResources.fromUri(
      Uri.parse('https://sylulive.online/uploads/article/photo.png?rev=3'),
    );

    expect(resources.isManagedUpload, isTrue);
    expect(
      resources.thumbUrl,
      'https://sylulive.online/uploads/article/photo_v1_thumb.png?rev=3',
    );
    expect(
      resources.mediumUrl,
      'https://sylulive.online/uploads/article/photo_v1_medium.png?rev=3',
    );

    final candidates = resources.candidatesFor(
      const ImageDecodeTarget(width: 320, height: 240),
    );
    expect(
      candidates.map((candidate) => candidate.variant),
      [
        CampusArticleImageVariant.thumb,
        CampusArticleImageVariant.medium,
        CampusArticleImageVariant.viewer,
        CampusArticleImageVariant.original,
      ],
    );
    expect(candidates.every((candidate) => candidate.shouldResize), isTrue);
  });

  test('较大文章图片优先 medium/viewer，GIF 变体使用静态 JPEG', () {
    final resources = CampusArticleImageResources.fromUri(
      Uri.parse('https://sylulive.online/uploads/article/animation.gif'),
    );

    final candidates = resources.candidatesFor(
      const ImageDecodeTarget(width: 900, height: 700),
    );
    expect(
      candidates.map((candidate) => candidate.variant),
      [
        CampusArticleImageVariant.medium,
        CampusArticleImageVariant.thumb,
        CampusArticleImageVariant.viewer,
        CampusArticleImageVariant.original,
      ],
    );
    expect(resources.mediumUrl, endsWith('_v1_medium.jpg'));
    expect(candidates.first.shouldResize, isTrue);
    expect(candidates.last.shouldResize, isFalse);
  });

  test('外部图片不生成本站变体，仅限制非 GIF 原图解码', () {
    const url = 'https://cdn.example.com/article/photo.jpg';
    final resources = CampusArticleImageResources.fromUri(Uri.parse(url));

    expect(resources.isManagedUpload, isFalse);
    final candidates = resources.candidatesFor(
      const ImageDecodeTarget(width: 640, height: 480),
    );
    expect(candidates, hasLength(1));
    expect(candidates.single.url, url);
    expect(candidates.single.variant, CampusArticleImageVariant.original);
    expect(candidates.single.shouldResize, isTrue);
  });
}
