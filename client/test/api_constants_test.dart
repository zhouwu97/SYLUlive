import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/config/api_constants.dart';

void main() {
  test('strips only the trailing api segment from an absolute base URL', () {
    expect(
      ApiConstants.apiRootFromBaseUrl('https://sylu.example.com/api'),
      'https://sylu.example.com',
    );
    expect(
      ApiConstants.apiRootFromBaseUrl('https://sylu.example.com/app/api/'),
      'https://sylu.example.com/app',
    );
  });

  test('same-origin web api root resolves uploaded resources as root paths',
      () {
    expect(ApiConstants.apiRootFromBaseUrl('/api'), '');
    expect(
      ApiConstants.fullUrlForBase('/uploads/a.png', '/api'),
      '/uploads/a.png',
    );
    expect(
      ApiConstants.fullUrlForBase('uploads/a.png', '/api'),
      '/uploads/a.png',
    );
  });

  test('absolute resource URLs pass through unchanged', () {
    expect(
      ApiConstants.fullUrlForBase(
        'https://cdn.example.com/a.png',
        'https://sylu.example.com/api',
      ),
      'https://cdn.example.com/a.png',
    );
  });

  test('sticker resources include a cache-busting asset version', () {
    expect(
      ApiConstants.versionStickerResourceUrl('/stickers/sticker-id'),
      '/stickers/sticker-id?v=${ApiConstants.stickerAssetVersion}',
    );
    expect(
      ApiConstants.versionStickerResourceUrl('/stickers/sticker-id?v=old'),
      '/stickers/sticker-id?v=${ApiConstants.stickerAssetVersion}',
    );
  });

  test('legacy http upload URLs can be normalized to same-origin paths', () {
    expect(
      ApiConstants.normalizeSameOriginResourceUrl(
        'http://legacy.example.com:8080/uploads/a/a.png',
      ),
      '/uploads/a/a.png',
    );
    expect(
      ApiConstants.normalizeSameOriginResourceUrl(
        'http://legacy.example.com:8080/uploads/a/a.png?v=1#preview',
      ),
      '/uploads/a/a.png?v=1#preview',
    );
    expect(
      ApiConstants.normalizeSameOriginResourceUrl(
        'http://example.com/not-upload/a.png',
      ),
      'http://example.com/not-upload/a.png',
    );
  });

  test('image variants preserve the resource path and query parameters', () {
    expect(
      ApiConstants.imageVariant('/uploads/a/a.jpg', 'thumb'),
      '/uploads/a/a_thumb.jpg',
    );
    expect(
      ApiConstants.imageVariant(
        'https://cdn.example.com/a_medium.webp?v=2',
        'medium',
      ),
      'https://cdn.example.com/a_medium.webp?v=2',
    );
    expect(
      ApiConstants.imageVariant('/uploads/a/a.png?x=1', 'medium'),
      '/uploads/a/a_medium.png?x=1',
    );
  });
}
