import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/config/app_contacts.dart';
import 'package:shenliyuan/screens/legal_documents_screen.dart';

import '../helpers/golden_test_app.dart';
import '../helpers/golden_viewport.dart';
import '../helpers/load_test_fonts.dart';

const _capture = bool.fromEnvironment('LEGAL_CONTACT_CAPTURE');

void main() {
  setUpAll(loadTestFonts);

  for (final theme in [ThemeMode.light, ThemeMode.dark]) {
    for (final id in ['user_agreement', 'privacy_policy']) {
      testWidgets('法律文档可滚动阅读三位作者邮箱，窄屏大字号：$theme $id', (tester) async {
        await setGoldenViewport(tester, GoldenViewports.phone360x800);
        final boundaryKey = GlobalKey();
        await tester.pumpWidget(RepaintBoundary(
          key: boundaryKey,
          child: GoldenTestApp(
            themeMode: theme,
            textScaler: const TextScaler.linear(1.3),
            home: LegalDocumentsScreen(initialDocumentId: id),
          ),
        ));
        await tester.pumpAndSettle();

        final body = find.textContaining(AppContacts.pureHomozygoteEmail);
        expect(body, findsOneWidget);
        final text = tester.widget<Text>(body).data!;
        expect(text, contains(AppContacts.developerNames));
        final scrollable =
            tester.state<ScrollableState>(find.byType(Scrollable).first);
        scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
        await tester.pumpAndSettle();
        final paragraph = tester.renderObject<RenderParagraph>(
          find.descendant(of: body, matching: find.byType(RichText)),
        );
        for (final email in [
          AppContacts.pureHomozygoteEmail,
          AppContacts.scoreDropperEmail,
          AppContacts.nowEmail,
        ]) {
          final offset = text.indexOf(email);
          expect(offset, greaterThanOrEqualTo(0));
          final boxes = paragraph.getBoxesForSelection(
            TextSelection(
                baseOffset: offset, extentOffset: offset + email.length),
          );
          expect(boxes, isNotEmpty);
          for (final box in boxes) {
            final rect =
                box.toRect().shift(paragraph.localToGlobal(Offset.zero));
            expect(rect.left, greaterThanOrEqualTo(0));
            expect(rect.right, lessThanOrEqualTo(360));
            expect(rect.top, greaterThanOrEqualTo(kToolbarHeight));
            expect(rect.bottom, lessThanOrEqualTo(800));
          }
        }
        expect(tester.takeException(), isNull);

        if (_capture) {
          final boundary = boundaryKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
          await tester.runAsync(() async {
            final image = await boundary.toImage(pixelRatio: 1);
            final bytes =
                await image.toByteData(format: ui.ImageByteFormat.png);
            final directory = Directory('build/legal-contact-captures');
            await directory.create(recursive: true);
            await File('${directory.path}/${theme.name}-$id.png')
                .writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
      });
    }
  }
}
