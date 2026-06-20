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

  test('legacy http upload URLs can be normalized to same-origin paths', () {
    expect(
      ApiConstants.normalizeSameOriginResourceUrl(
        'http://156.233.229.232:8080/uploads/a/a.png',
      ),
      '/uploads/a/a.png',
    );
    expect(
      ApiConstants.normalizeSameOriginResourceUrl(
        'http://156.233.229.232:8080/uploads/a/a.png?v=1#preview',
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
}
