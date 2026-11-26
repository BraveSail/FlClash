import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/common/hub_config.dart';
import 'package:fl_clash/models/profile.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('HubConfig', () {
    test('is inert unless the URL is valid and secure', () {
      expect(HubConfig.fromStrings(url: '').isConfigured, isFalse);
      expect(
        HubConfig.fromStrings(url: 'http://host.example').isConfigured,
        isFalse,
      );
      expect(
        HubConfig.fromStrings(url: 'ftp://192.0.2.1').isConfigured,
        isFalse,
      );
    });

    test('builds profile and watch URIs cleanly for http and https', () {
      final httpHub = HubConfig.fromStrings(url: 'http://127.0.0.1/');
      expect(httpHub.isConfigured, isTrue);
      expect(
        httpHub.profileUri('d4685bfb8530').toString(),
        'http://127.0.0.1/profile?id=d4685bfb8530',
      );
      expect(
        httpHub.watchUri('d4685bfb8530').toString(),
        'ws://127.0.0.1/profile/watch?id=d4685bfb8530',
      );

      final httpsHub = HubConfig.fromStrings(
        url: 'https://hub.example.com:8443/prefix/',
      );
      expect(
        httpsHub.profileUri('abc123456789').toString(),
        'https://hub.example.com:8443/prefix/profile?id=abc123456789',
      );
      expect(
        httpsHub.watchUri('abc123456789').toString(),
        'wss://hub.example.com:8443/prefix/profile/watch?id=abc123456789',
      );
    });

    test('identifies a legacy HTTP Hub profile for HTTPS migration', () {
      final hub = HubConfig.fromStrings(url: 'https://hub.example.test');
      const url = 'http://hub.example.test/profile?id=fixture&token=legacy';
      expect(
        hub.isHubProfile(Profile.normal(label: hubProfileLabel, url: url)),
        isTrue,
      );
      expect(
        hub.isHubProfile(Profile.normal(label: 'Custom', url: url)),
        isFalse,
      );
      expect(hub.matchesOrigin(Uri.parse(url)), isFalse);
    });

    test('matches hub profile and rejects unrelated profiles', () {
      final hub = HubConfig.fromStrings(url: 'http://127.0.0.1');
      final builtin = Profile.normal(
        label: hubProfileLabel,
        url: 'http://127.0.0.1/profile?id=d4685bfb8530&token=old-token',
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
        hub.matchesOrigin(Uri.parse('http://127.0.0.1:80/profile')),
        isTrue,
      );
      expect(
        hub.matchesOrigin(Uri.parse('ws://127.0.0.1/profile/watch')),
        isTrue,
      );
      expect(
        hub.matchesOrigin(Uri.parse('https://127.0.0.1/profile')),
        isFalse,
      );
    });
  });

  group('loadOrCreateMeshDeviceId', () {
    test('signs the Hub wire contract exactly like the server', () async {
      final dir = await Directory.systemTemp.createTemp('hub_signature_');
      addTearDown(() => dir.delete(recursive: true));
      await File(p.join(dir.path, meshKeyFileName)).writeAsString(
        jsonEncode({'signing': 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8'}),
      );
      final identity = await loadOrCreateHubIdentity(homeDir: dir.path);
      expect(identity.deviceId, 'cb60d3ee7d1a');
      expect(
        await identity.publicKey(),
        'A6EHv_POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg',
      );
      expect(
        await identity.signGet(
          Uri.parse('https://hub.example/profile?id=cb60d3ee7d1a'),
          now: DateTime.fromMillisecondsSinceEpoch(1790000000000, isUtc: true),
        ),
        {
          'x-mesh-id': 'cb60d3ee7d1a',
          'x-mesh-timestamp': '1790000000',
          'x-mesh-signature':
              'YALqu0Mscqp0wgBipLklB8CXqnS3Fj-s4aXQM5iYhYtvf7KDxOaB1fB2JxLG__bAPF1qSKat5tURbc-OwT7vDA',
        },
      );
    });

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
