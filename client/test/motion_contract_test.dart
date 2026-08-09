import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/theme/app_motion.dart';
import 'package:shenliyuan/utils/chat_scroll_intent.dart';

void main() {
  test('AppMotion exposes the frozen semantic durations', () {
    expect(AppMotion.micro, const Duration(milliseconds: 100));
    expect(AppMotion.tab, const Duration(milliseconds: 120));
    expect(AppMotion.fast, const Duration(milliseconds: 160));
    expect(AppMotion.normal, const Duration(milliseconds: 220));
    expect(AppMotion.overlay, const Duration(milliseconds: 240));
    expect(AppMotion.page, const Duration(milliseconds: 280));
    expect(AppMotion.reveal, const Duration(milliseconds: 320));
    expect(AppMotion.standard, Curves.easeOutCubic);
    expect(AppMotion.incoming, Curves.easeOutCubic);
    expect(AppMotion.outgoing, Curves.easeOutCubic);
    expect(AppMotion.movement, Curves.easeInOutCubic);
  });

  test('ChatScrollIntent has one explicit behavior per path', () {
    expect(
      ChatScrollIntent.ownSend.usesJumpScroll(reduceMotion: false),
      isTrue,
    );
    expect(
      ChatScrollIntent.restore.usesJumpScroll(reduceMotion: false),
      isTrue,
    );
    expect(
      ChatScrollIntent.incomingNearBottom.usesJumpScroll(reduceMotion: false),
      isFalse,
    );
    expect(
      ChatScrollIntent.incomingNearBottom.usesJumpScroll(reduceMotion: true),
      isTrue,
    );
    expect(ChatScrollIntent.messageFocus.showsFocusHighlight, isTrue);
    expect(
      ChatScrollIntent.messageFocus.usesAnimatedFocus(reduceMotion: false),
      isTrue,
    );
    expect(
      ChatScrollIntent.messageFocus.usesAnimatedFocus(reduceMotion: true),
      isFalse,
    );
  });
}
