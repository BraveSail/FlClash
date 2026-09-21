import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/views/config/hub.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_app.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;

  setUp(() {
    container = ProviderContainer();
    container.read(viewSizeProvider.notifier).value = const Size(1200, 1000);
  });

  tearDown(() => container.dispose());

  Future<void> pumpItem(WidgetTester tester, Widget item) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: TestApp(
          child: Scaffold(body: ListView(children: [item])),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the hub address item writes the trimmed setting', (
    tester,
  ) async {
    await pumpItem(tester, const HubUrlItem());

    await tester.tap(find.byType(ListTile).first);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextFormField),
      ' https://hub.example/ ',
    );
    await tester.tap(find.text(currentAppLocalizations.submit));
    await tester.pumpAndSettle();

    expect(container.read(appSettingProvider).hubUrl, 'https://hub.example/');
    expect(tester.takeException(), null);
  });

  testWidgets('the hub token item writes the setting from its dialog', (
    tester,
  ) async {
    await pumpItem(tester, const HubTokenItem());

    await tester.tap(find.byType(ListTile).first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), ' secret ');
    await tester.tap(find.text(currentAppLocalizations.submit));
    await tester.pumpAndSettle();

    expect(container.read(appSettingProvider).hubToken, 'secret');
    expect(tester.takeException(), null);
  });

  testWidgets('the via-proxy switch flips both ways', (tester) async {
    await pumpItem(tester, const HubViaProxyItem());

    expect(container.read(appSettingProvider).hubViaProxy, false);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(container.read(appSettingProvider).hubViaProxy, true);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(container.read(appSettingProvider).hubViaProxy, false);
    expect(tester.takeException(), null);
  });

  test('the hub settings survive a config round trip', () {
    const config = AppSettingProps(
      hubUrl: 'https://hub.example',
      hubToken: 'secret',
      hubViaProxy: true,
    );

    final restored = AppSettingProps.fromJson(config.toJson());

    expect(restored.hubUrl, 'https://hub.example');
    expect(restored.hubToken, 'secret');
    expect(restored.hubViaProxy, true);
  });
}
