import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/action.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/providers/core.dart';
import 'package:fl_clash/providers/database.dart';
import 'package:fl_clash/providers/hub_sync.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../helpers/app_paths.dart';
import '../helpers/test_profiles.dart';

class _MockCoreHandlerInterface extends Mock implements CoreHandlerInterface {}

class _RealHttpOverrides extends HttpOverrides {}

class _RecordingSetupAction extends SetupAction {
  int applyDebounceCount = 0;

  @override
  void applyProfileDebounce({bool silence = false, bool force = false}) {
    applyDebounceCount++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory home;
  late _MockCoreHandlerInterface core;
  late _RecordingSetupAction setupAction;
  late ProviderContainer container;

  setUp(() async {
    loadAppLocalizations(const Locale('en'));
    home = Directory.systemTemp.createTempSync('flclash-hub-sync-');
    await useAppPaths(home);
    core = _MockCoreHandlerInterface();
    when(() => core.validateConfig(any())).thenAnswer((_) async => null);
    when(() => core.clearEffect(any())).thenAnswer((_) async {});
    setupAction = _RecordingSetupAction();
    container = ProviderContainer(
      overrides: [
        profilesProvider.overrideWith(TestProfiles.new),
        coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
        setupActionProvider.overrideWith(() => setupAction),
      ],
    );
    globalState.container = container;
    // Mirror AppStateManager keeping auto-dispose config providers alive.
    container.listen(currentProfileIdProvider, (_, _) {});
    container.listen(hubSyncProvider, (_, _) {});
  });

  tearDown(() async {
    debugHubConfigOverride = null;
    container.dispose();
    if (home.existsSync()) {
      home.deleteSync(recursive: true);
    }
  });

  test(
    'ensureHubProfile adopts built-in Hub on fresh install and prevents deletion',
    () async {
      final hub = HubConfig.fromStrings(
        url: 'http://127.0.0.1:18999',
        token: 'test-token',
      );
      debugHubConfigOverride = hub;

      final deviceId = await container
          .read(profilesActionProvider.notifier)
          .ensureHubProfile(homeDir: home.path);
      expect(deviceId, isNotNull);
      expect(deviceId, matches(RegExp(r'^[0-9a-f]{12}$')));

      final profiles = container.read(profilesProvider);
      expect(profiles, hasLength(1));
      final hubProfile = profiles.single;
      expect(hubProfile.label, hubProfileLabel);
      expect(hubProfile.url, hub.profileUri(deviceId!).toString());
      expect(container.read(currentProfileIdProvider), hubProfile.id);

      // Built-in Hub profile cannot be deleted.
      await container
          .read(profilesActionProvider.notifier)
          .deleteProfile(hubProfile.id);
      expect(container.read(profilesProvider), hasLength(1));

      // User can add another profile, switch to it, and delete it.
      final customId = container
          .read(profilesActionProvider.notifier)
          .addCustomProfile('My Custom');
      container.read(currentProfileIdProvider.notifier).value = customId;
      expect(container.read(profilesProvider), hasLength(2));
      expect(container.read(currentProfileIdProvider), customId);

      await container
          .read(profilesActionProvider.notifier)
          .deleteProfile(customId);
      expect(container.read(profilesProvider), hasLength(1));
      expect(container.read(currentProfileIdProvider), hubProfile.id);
    },
  );

  test(
    'ensureHubProfile reconciles stale device id / token without duplicating',
    () async {
      final hub = HubConfig.fromStrings(
        url: 'http://127.0.0.1:18999',
        token: 'new-token',
      );
      debugHubConfigOverride = hub;

      final stale = Profile.normal(
        label: 'OldName',
        url: 'http://127.0.0.1:18999/profile?id=default&token=old-token',
      ).copyWith(selectedMap: {'Proxy': 'hk-node'});
      container.read(profilesProvider.notifier).put(stale);
      container.read(currentProfileIdProvider.notifier).value = stale.id;

      final deviceId = await container
          .read(profilesActionProvider.notifier)
          .ensureHubProfile(homeDir: home.path);

      final profiles = container.read(profilesProvider);
      expect(profiles, hasLength(1));
      final updated = profiles.single;
      expect(updated.id, stale.id);
      expect(updated.label, hubProfileLabel);
      expect(updated.url, hub.profileUri(deviceId!).toString());
      expect(updated.selectedMap, {'Proxy': 'hk-node'});
    },
  );

  test(
    'HubSync polls with ETag, handles 304, receives WS push, and respects active profile',
    () => HttpOverrides.runWithHttpOverrides(() async {
      const currentYaml = 'proxies: []\nrules:\n  - MATCH,DIRECT\n';
      const currentEtag = '"etag-1"';
      var profileRequests = 0;
      WebSocket? serverSocket;
      final wsConnected = Completer<void>();

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await serverSocket?.close();
        await server.close(force: true);
      });
      server.listen((req) async {
        if (req.uri.path == '/profile') {
          profileRequests++;
          final inm = req.headers.value(HttpHeaders.ifNoneMatchHeader);
          if (inm == currentEtag) {
            req.response.statusCode = HttpStatus.notModified;
            await req.response.close();
            return;
          }
          req.response
            ..statusCode = HttpStatus.ok
            ..headers.set(HttpHeaders.etagHeader, currentEtag)
            ..write(currentYaml);
          await req.response.close();
          return;
        }
        if (req.uri.path == '/profile/watch') {
          serverSocket = await WebSocketTransformer.upgrade(req);
          if (!wsConnected.isCompleted) wsConnected.complete();
          return;
        }
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
      });

      final hub = HubConfig.fromStrings(
        url: 'http://127.0.0.1:${server.port}',
        token: 'tok-123',
      );
      debugHubConfigOverride = hub;

      final deviceId = await container
          .read(profilesActionProvider.notifier)
          .ensureHubProfile(homeDir: home.path);
      final hubProfile = container.read(profilesProvider).single;

      final sync = container.read(hubSyncProvider.notifier);
      sync.start(deviceId: deviceId!, config: hub);
      await wsConnected.future.timeout(const Duration(seconds: 5));

      // Wait for initial poll to commit v1.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final file = File(await appPath.getProfilePath(hubProfile.id.toString()));
      expect(await file.exists(), isTrue);
      expect(await file.readAsString(), currentYaml);
      expect(setupAction.applyDebounceCount, 1);

      // Conditional poll with same ETag returns 304 -> no reload.
      final changedOn304 = await sync.pollOnce();
      expect(changedOn304, isFalse);
      expect(setupAction.applyDebounceCount, 1);
      expect(profileRequests, greaterThanOrEqualTo(2));

      // Switch user to a custom profile, then push v2 via WebSocket.
      final userProfileId = container
          .read(profilesActionProvider.notifier)
          .addCustomProfile('User Own');
      container.read(currentProfileIdProvider.notifier).value = userProfileId;

      const v2Yaml =
          'proxies: []\nrules:\n  - DOMAIN,example.com,DIRECT\n  - MATCH,DIRECT\n';
      serverSocket!.add(
        jsonEncode({'type': 'profile', 'yaml': v2Yaml, 'etag': '"etag-2"'}),
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));

      // Hub file updated passively, but user's selection was NOT hijacked or reloaded!
      expect(await file.readAsString(), v2Yaml);
      expect(container.read(currentProfileIdProvider), userProfileId);
      expect(setupAction.applyDebounceCount, 1);

      sync.stop();
    }, _RealHttpOverrides()),
  );
}
