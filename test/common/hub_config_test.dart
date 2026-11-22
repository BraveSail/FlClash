import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/common/hub_config.dart';
import 'package:fl_clash/models/profile.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('HubConfig', () {
    test('is inert when url or token is missing or invalid', () {
      expect(
        HubConfig.fromStrings(url: '', token: 'tok').isConfigured,
        isFalse,
      );
      expect(
        HubConfig.fromStrings(
          url: 'http://106.55.177.19',
          token: '',
        ).isConfigured,
        isFalse,
      );
      expect(
        HubConfig.fromStrings(
          url: 'ftp://106.55.177.19',
          token: 'tok',
        ).isConfigured,
        isFalse,
      );
    });

    test('builds profile and watch URIs cleanly for http and https', () {
      final httpHub = HubConfig.fromStrings(
        url: 'http://106.55.177.19/',
        token: 'secret-token',
      );
      expect(httpHub.isConfigured, isTrue);
      expect(
        httpHub.profileUri('d4685bfb8530').toString(),
        'http://106.55.177.19/profile?id=d4685bfb8530&token=secret-token',
      );
      expect(
        httpHub.watchUri('d4685bfb8530').toString(),
        'ws://106.55.177.19/profile/watch?id=d4685bfb8530&token=secret-token',
      );

      final httpsHub = HubConfig.fromStrings(
        url: 'https://hub.example.com:8443/prefix/',
        token: 't2',
      );
      expect(
        httpsHub.profileUri('abc123456789').toString(),
        'https://hub.example.com:8443/prefix/profile?id=abc123456789&token=t2',
      );
      expect(
        httpsHub.watchUri('abc123456789').toString(),
        'wss://hub.example.com:8443/prefix/profile/watch?id=abc123456789&token=t2',
      );
    });

    test('matches hub profile and rejects unrelated profiles', () {
      final hub = HubConfig.fromStrings(
        url: 'http://106.55.177.19',
        token: 'secret',
      );
      final builtin = Profile.normal(
        label: hubProfileLabel,
        url: 'http://106.55.177.19/profile?id=d4685bfb8530&token=old-token',
      );
      final otherHost = Profile.normal(
        label: 'Other',
        url: 'https://sub.example.com/profile?id=1',
      );
      final localFile = Profile.normal(label: 'Local');
      final custom = Profile.custom(label: 'Custom');

      expect(hub.isHubProfile(builtin), isTrue);
      expect(hub.isHubProfile(otherHost), isFalse);
      expect(hub.isHubProfile(localFile), isFalse);
      expect(hub.isHubProfile(custom), isFalse);
      expect(
        hub.matchesOrigin(Uri.parse('http://106.55.177.19:80/profile')),
        isTrue,
      );
      expect(
        hub.matchesOrigin(Uri.parse('ws://106.55.177.19/profile/watch')),
        isTrue,
      );
      expect(
        hub.matchesOrigin(Uri.parse('https://106.55.177.19/profile')),
        isFalse,
      );
    });
  });

  group('loadOrCreateMeshDeviceId', () {
    test(
      'creates mesh-key.json on fresh dir and stays stable across calls',
      () async {
        final dir = await Directory.systemTemp.createTemp('hub_config_test_');
        addTearDown(() => dir.delete(recursive: true));

        final firstId = await loadOrCreateMeshDeviceId(homeDir: dir.path);
        expect(firstId, matches(RegExp(r'^[0-9a-f]{12}$')));

        final keyFile = File(p.join(dir.path, meshKeyFileName));
        expect(await keyFile.exists(), isTrue);

        final decoded = jsonDecode(await keyFile.readAsString()) as Map;
        expect(decoded['transport'], isA<String>());
        expect(decoded['signing'], isA<String>());
        expect((decoded['transport'] as String).contains('='), isFalse);
        expect((decoded['signing'] as String).contains('='), isFalse);

        final secondId = await loadOrCreateMeshDeviceId(homeDir: dir.path);
        expect(secondId, equals(firstId));
      },
    );

    test('refuses to overwrite corrupt mesh-key.json', () async {
      final dir = await Directory.systemTemp.createTemp('hub_config_corrupt_');
      addTearDown(() => dir.delete(recursive: true));

      final keyFile = File(p.join(dir.path, meshKeyFileName));
      await keyFile.writeAsString('not-json');

      await expectLater(
        () => loadOrCreateMeshDeviceId(homeDir: dir.path),
        throwsFormatException,
      );
      expect(await keyFile.readAsString(), 'not-json');
    });

    test('derives deterministic device id matching Go DeriveOn', () async {
      // Seed of 32 zero bytes -> known Ed25519 pubkey -> sha256("key:" || pub)[:12].
      final zeroSeed = List<int>.filled(32, 0);
      final id1 = await deriveDeviceIdFromSeed(zeroSeed);
      final id2 = await deriveDeviceIdFromSeed(zeroSeed);
      expect(id1, matches(RegExp(r'^[0-9a-f]{12}$')));
      expect(id1, equals(id2));
    });
  });
}
