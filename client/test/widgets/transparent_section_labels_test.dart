import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/widgets/ai/ai_empty_state.dart';
import 'package:shenliyuan/widgets/ai/ai_personal_empty_state.dart';
import 'package:shenliyuan/widgets/app_card.dart';
import 'package:shenliyuan/widgets/campus/campus_news_section_header.dart';
import 'package:shenliyuan/widgets/campus/campus_service_grid.dart';
import 'package:shenliyuan/widgets/settings/settings_section.dart';

import '../helpers/golden_test_app.dart';
import '../helpers/golden_viewport.dart';
import '../helpers/load_test_fonts.dart';

void main() {
  setUpAll(loadTestFonts);
  for (final scene in [
    'settings',
    'services',
    'news',
    'public-ai',
    'personal-ai'
  ]) {
    for (final dark in [false, true]) {
      for (final scale in [1.0, 1.3]) {
        testWidgets('$scene 短标题无额外底色且开关不移位 dark=$dark scale=$scale',
            (tester) async {
          await setGoldenViewport(tester, GoldenViewports.phone390x844);
          AppPreferencesStore.setMockInitialValues({});
          final appearance = ThemeProvider(loadOnStart: false);
          addTearDown(appearance.dispose);
          await appearance.setBackgroundImage('morenbeijing.jpeg');
          await appearance.setComponentOpacity(.75);
          var actions = 0;
          void action() => actions++;
          final (captions, body) = switch (scene) {
            'settings' => (
                ['偏好设置'],
                const SettingsSection(
                    title: '偏好设置', children: [Text('保留原设置卡片')])
              ),
            'services' => (
                ['校园服务', '常用校园功能'],
                CampusServiceGrid(
                    isDark: dark,
                    onEduTap: action,
                    onCanteenTap: action,
                    onRateTap: action,
                    onTeamTap: action,
                    onMapTap: action,
                    onCalendarTap: action)
              ),
            'news' => (
                ['校园资讯', '校园通知与赛事信息'],
                CampusNewsSectionHeader(isDark: dark, onCompetitionTap: action)
              ),
            'public-ai' => (
                ['今天想让 Agent 帮你做什么？', '常用能力'],
                const AiPublicEmptyState(chatEnabled: true, quickPrompts: [])
              ),
            _ => (
                ['个人助手', '本机能力'],
                AiPersonalEmptyState(
                    needsModelConfiguration: true,
                    onConfigureModel: action,
                    onActionSelected: (_) => action())
              ),
          };
          await tester.pumpWidget(ChangeNotifierProvider.value(
            value: appearance,
            child: GoldenTestApp(
              themeMode: dark ? ThemeMode.dark : ThemeMode.light,
              textScaler: TextScaler.linear(scale),
              home: Scaffold(body: body),
            ),
          ));
          await tester.pumpAndSettle();
          final before = {
            for (final caption in captions)
              caption: tester.getRect(find.text(caption))
          };
          for (final glass in [false, true, false]) {
            await appearance.setFrostedGlass(glass);
            await tester.pumpAndSettle();
            for (final caption in captions) {
              final text = find.text(caption);
              expect(tester.getRect(text), before[caption]);
              expect(
                  find.ancestor(
                      of: text, matching: find.byType(AppContentSurface)),
                  findsNothing);
              expect(
                  find.ancestor(
                      of: text, matching: find.byType(AppCardSurface)),
                  findsNothing);
            }
            if (scene == 'public-ai' || scene == 'personal-ai') {
              final description = find.text(scene == 'public-ai'
                  ? '它会先查学校资料和已授权快照；\n只有数据确实缺失或过期时，才会请求你的手机继续完成。'
                  : '使用你配置的模型和本机 ToolLoop。\n它和校园 Agent 的服务端 Run、MCP 设备任务是两条不同链路。');
              expect(
                  find.ancestor(
                      of: description,
                      matching: find.byType(AppContentSurface)),
                  findsOneWidget,
                  reason: '说明正文应有底面，不能与页面标题一并移除');
            }
            if (scene != 'news') {
              expect(find.byType(AppCardSurface), findsWidgets,
                  reason: '标题透明不应移除原有内容卡片');
            }
            expect(tester.takeException(), isNull);
          }
          if (scene == 'news') {
            await tester.tap(find.text('竞赛'));
            expect(actions, 1);
          }
        });
      }
    }
  }
}
