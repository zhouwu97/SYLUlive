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
}
