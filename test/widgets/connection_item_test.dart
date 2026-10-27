import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/features/features.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_app.dart';

TrackerInfo _tracker({
  String rule = 'DOMAIN-SUFFIX',
  String rulePayload = '',
  String process = '',
  int uid = 0,
  String sourceIP = '',
  String sourcePort = '',
  String destinationIP = '',
  String destinationPort = '',
  String host = '',
  List<String> chains = const [],
}) {
  return TrackerInfo(
    id: '1',
    start: DateTime(2026, 1, 1, 10, 30),
    metadata: Metadata(
      network: 'tcp',
      process: process,
      uid: uid,
      sourceIP: sourceIP,
      sourcePort: sourcePort,
      destinationIP: destinationIP,
      destinationPort: destinationPort,
      host: host,
    ),
    chains: chains,
    rule: rule,
    rulePayload: rulePayload,
  );
}

void main() {
  testWidgets('TrackerInfoDetailView renders formatted connection fields', (
    tester,
  ) async {
    await tester.pumpWidget(
      TestApp(
        homeBuilder: (child) => Scaffold(body: child),
        child: SheetProvider(
          type: SheetType.page,
          child: TrackerInfoDetailView(
            trackerInfo: _tracker(
              rule: 'DOMAIN-SUFFIX',
              rulePayload: 'example.com',
              process: 'chrome',
              uid: 1000,
              sourceIP: '1.2.3.4',
              sourcePort: '8080',
              destinationIP: '5.6.7.8',
              destinationPort: '443',
              host: 'example.com',
              chains: const ['DIRECT'],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('DOMAIN-SUFFIX(example.com)'), findsOneWidget);
    expect(find.text('chrome(1000)'), findsOneWidget);
    expect(find.text('1.2.3.4:8080'), findsOneWidget);
    expect(find.text('5.6.7.8:443'), findsOneWidget);
    expect(find.text('example.com'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('DIRECT'),
      100,
      scrollable: find.byType(Scrollable),
    );
    expect(find.text('DIRECT'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('TrackerInfoDetailView omits empty fields', (tester) async {
    await tester.pumpWidget(
      TestApp(
        homeBuilder: (child) => Scaffold(body: child),
        child: SheetProvider(
          type: SheetType.page,
          child: TrackerInfoDetailView(trackerInfo: _tracker()),
        ),
      ),
    );
    await tester.pump();

    expect(find.textContaining('('), findsNothing);
    expect(find.text('tcp'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('TrackerInfoItem shows all chains and forwards their clicks', (
    tester,
  ) async {
    final clicked = <String>[];
    await tester.pumpWidget(
      TestApp(
        wrapInProviderScope: true,
        homeBuilder: (child) => Scaffold(body: child),
        child: TrackerInfoItem(
          trackerInfo: _tracker(chains: const ['Proxy A', 'Proxy B']),
          detailTitle: 'detail',
          onClickKeyword: clicked.add,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Proxy A'), findsOneWidget);
    expect(find.text('Proxy B'), findsOneWidget);

    await tester.tap(find.text('Proxy A'));
    await tester.pump();
    await tester.tap(find.text('Proxy B'));
    await tester.pump();

    expect(clicked, ['Proxy A', 'Proxy B']);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('TrackerInfoItem lets long chain entries wrap', (
    tester,
  ) async {
    const transport = 'direct 2404:c140:1f00:32::1b:1fbf:41641';
    await tester.pumpWidget(
      TestApp(
        wrapInProviderScope: true,
        homeBuilder: (child) => Scaffold(body: child),
        child: TrackerInfoItem(
          trackerInfo: _tracker(chains: const ['PEER', transport]),
          detailTitle: 'detail',
        ),
      ),
    );
    await tester.pump();

    expect(tester.widget<Text>(find.text(transport)).maxLines, 3);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('TrackerInfoDetailView lets long chain entries wrap', (
    tester,
  ) async {
    const transport = 'direct 2404:c140:1f00:32::1b:1fbf:41641';
    await tester.pumpWidget(
      TestApp(
        homeBuilder: (child) => Scaffold(body: child),
        child: SheetProvider(
          type: SheetType.page,
          child: TrackerInfoDetailView(
            trackerInfo: _tracker(chains: const [transport]),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.scrollUntilVisible(
      find.text(transport),
      100,
      scrollable: find.byType(Scrollable),
    );
    expect(tester.widget<Text>(find.text(transport)).maxLines, 3);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('TrackerInfoDetailView copies a chain on tap', (tester) async {
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        calls.add(call);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    const transport = 'direct 2404:c140:1f00:32::1b:1fbf:41641';
    await tester.pumpWidget(
      TestApp(
        homeBuilder: (child) => Scaffold(body: child),
        child: SheetProvider(
          type: SheetType.page,
          child: TrackerInfoDetailView(
            trackerInfo: _tracker(chains: const [transport]),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.scrollUntilVisible(
      find.text(transport),
      100,
      scrollable: find.byType(Scrollable),
    );
    await tester.tap(find.text(transport));
    await tester.pump();
    await tester.pump();

    final sets = calls
        .where((call) => call.method == 'Clipboard.setData')
        .toList();
    expect(sets, isNotEmpty);
    expect((sets.last.arguments as Map)['text'], transport);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
