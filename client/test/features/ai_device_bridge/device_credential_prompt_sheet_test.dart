import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/ai_device_bridge/device_credential_prompt_sheet.dart';

void main() {
  testWidgets('二课缺少凭据时在当前导航器弹出双密码窗口', (tester) async {
    DeviceCredentialInput? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () async {
                result = await DeviceCredentialPromptSheet.request(
                  context,
                  kind: DeviceCredentialKind.erke,
                  sourceAccountId: '20260001',
                );
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.text('更新二课数据'), findsOneWidget);
    expect(find.text('统一认证密码'), findsOneWidget);
    expect(find.text('二课查询密码'), findsOneWidget);
    expect(find.text('安全保存到本机'), findsOneWidget);

    await tester.enterText(find.byType(TextFormField).at(0), 'cas-secret');
    await tester.enterText(find.byType(TextFormField).at(1), 'erke-secret');
    await tester.tap(find.text('验证并继续'));
    await tester.pumpAndSettle();

    expect(result?.password, 'cas-secret');
    expect(result?.secondaryPassword, 'erke-secret');
    expect(result?.saveOnDevice, isTrue);
  });

  testWidgets('体测密码窗口支持暗色与大字体且可选择不保存', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    DeviceCredentialInput? result;

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
        child: MaterialApp(
          theme: ThemeData.dark(),
          home: Builder(
            builder: (context) => Scaffold(
              body: FilledButton(
                onPressed: () async {
                  result = await DeviceCredentialPromptSheet.request(
                    context,
                    kind: DeviceCredentialKind.physical,
                    sourceAccountId: '20260001',
                  );
                },
                child: const Text('打开体测'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开体测'));
    await tester.pumpAndSettle();
    expect(find.text('更新体测数据'), findsOneWidget);
    expect(find.text('体测密码'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byType(Checkbox));
    await tester.enterText(find.byType(TextFormField), 'physical-secret');
    await tester.tap(find.text('验证并继续'));
    await tester.pumpAndSettle();

    expect(result?.password, 'physical-secret');
    expect(result?.saveOnDevice, isFalse);
    expect(tester.takeException(), isNull);
  });
}
