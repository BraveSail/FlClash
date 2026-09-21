import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/theme.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/manager/status_manager.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/views/profiles/add.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_app.dart';

ProviderContainer _containerFor(WidgetTester tester) {
  const size = Size(1400, 1000);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final container = ProviderContainer();
  addTearDown(container.dispose);
  globalState.container = container;
  container.read(viewSizeProvider.notifier).update((_) => size);
  return container;
}

/// The manager stack mounts [StatusManager] above the app navigator, which is
/// what [AddProfileView] reaches through [Dialogs.showNotifier].
Future<void> _pumpAddProfileView(
  WidgetTester tester,
  ProviderContainer container,
) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        navigatorKey: globalState.navigatorKey,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          ...GlobalMaterialLocalizations.delegates,
        ],
        supportedLocales: AppLocalizations.delegate.supportedLocales,
        builder: (context, child) {
          globalState.measure = Measure.of(context, 1);
          globalState.theme = CommonTheme.of(context, 1);
          return StatusManager(child: child!);
        },
        home: Scaffold(
          body: Builder(builder: (context) => AddProfileView(context: context)),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('lists the QR code, file, and URL import entries', (
    tester,
  ) async {
    final container = _containerFor(tester);

    await _pumpAddProfileView(tester, container);

    final l10n = currentAppLocalizations;
    expect(find.text(l10n.qrcode), findsOne);
    expect(find.text(l10n.file), findsOne);
    expect(find.text(l10n.url), findsOne);
    expect(tester.takeException(), null);
  });

  testWidgets('a configured hub dims the import entries and refuses a tap', (
    tester,
  ) async {
    final container = _containerFor(tester);
    container.read(appSettingProvider.notifier).value = const AppSettingProps(
      hubUrl: 'https://hub.example',
      hubToken: 'secret',
    );

    await _pumpAddProfileView(tester, container);

    final l10n = currentAppLocalizations;
    expect(find.text(l10n.hub), findsOne);
    expect(find.text(l10n.hubManagedTip), findsOne);
    expect(tester.widget<DisabledMask>(find.byType(DisabledMask)).status, true);

    await tester.tap(find.text(l10n.url));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(InputDialog), findsNothing);
    expect(find.text(l10n.hubImportDisabledTip), findsOne);
    expect(tester.takeException(), null);
  });

  testWidgets('an address without a token keeps the import entries usable', (
    tester,
  ) async {
    final container = _containerFor(tester);
    container.read(appSettingProvider.notifier).value = const AppSettingProps(
      hubUrl: 'https://hub.example',
    );

    await _pumpAddProfileView(tester, container);

    final l10n = currentAppLocalizations;
    expect(find.text(l10n.hub), findsNothing);
    expect(
      tester.widget<DisabledMask>(find.byType(DisabledMask)).status,
      false,
    );

    await tester.tap(find.text(l10n.url));
    await tester.pumpAndSettle();

    expect(find.byType(InputDialog), findsOne);
    expect(tester.takeException(), null);
  });

  testWidgets('URL import dialog rejects an empty value and keeps the sheet', (
    tester,
  ) async {
    final container = _containerFor(tester);
    String? popped;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: TestApp(
          child: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  popped = await showDialog<String>(
                    context: context,
                    builder: (_) => const URLFormDialog(),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(URLFormDialog), findsOne);

    await tester.tap(find.text(currentAppLocalizations.submit));
    await tester.pumpAndSettle();

    expect(
      find.byType(URLFormDialog),
      findsOne,
      reason: 'an empty URL must not close the dialog',
    );
    expect(popped, isNull);
    expect(tester.takeException(), null);
  });

  testWidgets('URL import dialog returns the entered value', (tester) async {
    final container = _containerFor(tester);
    String? popped;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: TestApp(
          child: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  popped = await showDialog<String>(
                    context: context,
                    builder: (_) => const URLFormDialog(),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byType(TextField),
      'https://example.com/profile',
    );
    await tester.tap(find.text(currentAppLocalizations.submit));
    await tester.pumpAndSettle();

    expect(find.byType(URLFormDialog), findsNothing);
    expect(popped, 'https://example.com/profile');
    expect(tester.takeException(), null);
  });
}
