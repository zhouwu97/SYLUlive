import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/screens/image_viewer_screen.dart';

void main() {
  testWidgets('全屏私信图片保留 bearer token', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ImageViewerScreen(
          imageUrls: const ['https://example.test/private.jpg'],
          httpHeaders: const {'Authorization': 'Bearer viewer-token'},
        ),
      ),
    );
    await tester.pump();

    final image = tester.widget<CachedNetworkImage>(
      find.byType(CachedNetworkImage),
    );
    expect(image.httpHeaders, {'Authorization': 'Bearer viewer-token'});
  });
}
