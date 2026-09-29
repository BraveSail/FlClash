import 'package:fl_clash/common/common.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isHubEnabled', () {
    test('needs both the address and the token', () {
      expect(isHubEnabled('https://hub.example', 'token'), isTrue);
      expect(isHubEnabled(' https://hub.example ', ' token '), isTrue);
      expect(isHubEnabled('', 'token'), isFalse);
      expect(isHubEnabled('https://hub.example', ''), isFalse);
      expect(isHubEnabled('  ', '  '), isFalse);
    });
  });

  group('hubProfileUrl', () {
    test('drops the trailing slashes and carries the device id', () {
      expect(
        hubProfileUrl('https://hub.example/', 'a3f8b2c91d04'),
        'https://hub.example/profile?id=a3f8b2c91d04',
      );
      expect(
        hubProfileUrl('https://hub.example///', 'a3f8b2c91d04'),
        'https://hub.example/profile?id=a3f8b2c91d04',
      );
    });

    test('asks without an id when the device has none', () {
      expect(
        hubProfileUrl('https://hub.example', '  '),
        'https://hub.example/profile',
      );
    });

    test('is empty without an address', () {
      expect(hubProfileUrl('  ', 'a3f8b2c91d04'), '');
    });
  });

  group('isHubUrl', () {
    test('matches the same origin only', () {
      expect(
        isHubUrl('https://hub.example/profile?id=x', 'https://hub.example'),
        isTrue,
      );
      expect(
        isHubUrl('https://hub.example/profile?id=x', 'https://hub.example/'),
        isTrue,
      );
      expect(
        isHubUrl('https://other.example/profile', 'https://hub.example'),
        isFalse,
      );
      expect(
        isHubUrl('http://hub.example/profile', 'https://hub.example'),
        isFalse,
      );
      expect(
        isHubUrl('https://hub.example:8443/profile', 'https://hub.example'),
        isFalse,
      );
      expect(isHubUrl('https://hub.example/profile', ''), isFalse);
    });
  });

  group('hubProfileWatchUrl', () {
    test('addresses the socket and carries the revision it runs', () {
      expect(
        hubProfileWatchUrl('https://hub.example/', 'a3f8b2c91d04', '"42"'),
        'https://hub.example/profile/watch?id=a3f8b2c91d04&etag=%2242%22',
      );
    });

    test('asks without an etag when the device has none to name', () {
      expect(
        hubProfileWatchUrl('https://hub.example', 'a3f8b2c91d04', '  '),
        'https://hub.example/profile/watch?id=a3f8b2c91d04',
      );
    });

    test('is empty without an address or an id', () {
      expect(hubProfileWatchUrl('  ', 'a3f8b2c91d04', ''), '');
      expect(hubProfileWatchUrl('https://hub.example', '  ', ''), '');
    });
  });

  group('hubSocketUrl', () {
    test('matches the scheme the client already reaches the hub with', () {
      expect(
        hubSocketUrl('https://hub.example/profile/watch?id=x'),
        'wss://hub.example/profile/watch?id=x',
      );
      // A hub on a LAN is plain http, and a socket to it has to stay plain too
      // or the upgrade never completes.
      expect(
        hubSocketUrl('http://192.168.1.9:8787/profile/watch?id=x'),
        'ws://192.168.1.9:8787/profile/watch?id=x',
      );
    });

    test('leaves an address it does not know the scheme of alone', () {
      expect(hubSocketUrl(''), '');
      expect(hubSocketUrl('ws://hub.example/x'), 'ws://hub.example/x');
    });
  });

  group('hubAuthHeaders', () {
    test('sends the token as a bearer credential', () {
      expect(hubAuthHeaders(' secret '), {'Authorization': 'Bearer secret'});
    });
  });

  group('hubMeshUrl', () {
    test('names the device the hub answers for', () {
      expect(
        hubMeshUrl('https://hub.example/', 'aaaa1111'),
        'https://hub.example/api/mesh?id=aaaa1111',
      );
      expect(hubMeshUrl('', 'aaaa1111'), '');
      expect(hubMeshUrl('https://hub.example', ''), '');
    });
  });

  group('parseMeshPlan', () {
    test('reads the credentials and the devices the hub answered', () {
      final plan = parseMeshPlan({
        'id': 'aaaa1111',
        'port': 23333,
        'uuid': 'uuid-value',
        'decryption': 'server-half',
        'encryption': 'client-half',
        'devices': [
          {
            'id': 'bbbb2222',
            'name': 'PC',
            'addr': '2408:8256:d284:feb7:485:945b:beed:f9fb',
            'port': 9443,
          },
          {
            'id': 'cccc3333',
            'name': 'gt7',
            'addr': '2408:8256:d284:feb7:ee92:eff5:3fd6:7819',
            'port': 8443,
            'domain': 'gt7.lan',
          },
        ],
      });

      expect(plan, isNotNull);
      expect(plan!.port, 23333);
      expect(plan.uuid, 'uuid-value');
      expect(plan.decryption, 'server-half');
      expect(plan.encryption, 'client-half');
      expect(plan.devices, hasLength(2));
      expect(plan.devices.first.id, 'bbbb2222');
      expect(plan.devices.first.port, 9443);
      expect(plan.devices.last.domain, 'gt7.lan');
    });

    test('has nothing to dial without a user to speak as', () {
      expect(parseMeshPlan({'id': 'aaaa1111', 'devices': []}), isNull);
      expect(parseMeshPlan({'uuid': '  '}), isNull);
      expect(parseMeshPlan(null), isNull);
      expect(parseMeshPlan('nope'), isNull);
    });

    test('falls back to the default port when the hub names none', () {
      final plan = parseMeshPlan({'uuid': 'uuid-value'});
      expect(plan!.port, meshDefaultPort);
      expect(plan.devices, isEmpty);
    });
  });

  group('parseMeshDevices', () {
    test('keeps a device only when it can be dialled', () {
      final warnings = <String>[];
      final devices = parseMeshDevices([
        {
          'id': 'aaaa1111',
          'name': 'PC',
          'addr': '2408:8256:d284:feb7:485:945b:beed:f9fb',
        },
        {'id': 'bbbb2222', 'name': 'no-address'},
        {
          'id': 'bad id',
          'name': 'odd',
          'addr': '2408:8256:d284:feb7:2a56:3aff:fe62:ef40',
        },
      ], warnings: warnings);

      expect(devices, hasLength(1));
      expect(devices.single.name, 'PC');
      expect(warnings, hasLength(1));
    });

    test('carries a port written on the address, and a bracketed v6 host', () {
      final devices = parseMeshDevices([
        {'id': 'aaaa1111', 'name': 'PC', 'addr': '[fdfe::1]:9443'},
        {'id': 'bbbb2222', 'name': 'gt7', 'addr': 'host.example:8443'},
      ]);

      expect(devices, hasLength(2));
      expect(devices.first.addr, '[fdfe::1]');
      expect(devices.first.port, 9443);
      expect(devices.last.addr, 'host.example');
      expect(devices.last.port, 8443);
    });

    test('drops a domain the core would refuse', () {
      final devices = parseMeshDevices([
        {
          'id': 'aaaa1111',
          'name': 'PC',
          'addr': '2408:8256:d284:feb7:485:945b:beed:f9fb',
          'domain': 'not a domain',
        },
        {
          'id': 'bbbb2222',
          'name': 'gt7',
          'addr': '2408:8256:d284:feb7:ee92:eff5:3fd6:7819',
          'domain': 'gt7.lan',
        },
      ]);

      expect(devices, hasLength(2));
      expect(devices.first.domain, isEmpty);
      expect(devices.last.domain, 'gt7.lan');
    });

    test('reaches two devices of one name by their ids', () {
      final devices = parseMeshDevices([
        {
          'id': 'aaaa1111',
          'name': 'dup',
          'addr': '2408:8256:d284:feb7:485:945b:beed:f9fb',
        },
        {
          'id': 'bbbb2222',
          'name': 'dup',
          'addr': '2408:8256:d284:feb7:ee92:eff5:3fd6:7819',
        },
      ]);

      expect(devices, hasLength(2));
      expect(devices.map((d) => d.name), containsAll(['dup', 'bbbb2222']));
    });

    test(
      'brackets a bare IPv6 address instead of reading a port out of it',
      () {
        // The hub reports the address a peer is reached at without brackets;
        // every group after the first would otherwise parse as a port and the
        // device would be dropped.
        final devices = parseMeshDevices([
          {
            'id': 'aaaa1111',
            'name': 'router',
            'addr': '2408:8256:d284:feb7:2a56:3aff:fe62:ef40',
            'port': 23333,
          },
        ]);

        expect(devices, hasLength(1));
        expect(
          devices.single.addr,
          '[2408:8256:d284:feb7:2a56:3aff:fe62:ef40]',
        );
        expect(devices.single.port, 23333);
      },
    );
  });

  group('expandMesh', () {
    final plan = parseMeshPlan({
      'id': 'aaaa1111',
      'port': 23333,
      'uuid': 'uuid-value',
      'decryption': 'server-half',
      'encryption': 'client-half',
      'devices': [
        {
          'id': 'aaaa1111',
          'name': 'PC',
          'addr': '2408:8256:d284:feb7:485:945b:beed:f9fb',
          'domain': 'pc.lan',
        },
        {
          'id': 'bbbb2222',
          'name': 'gt7',
          'addr': '2408:8256:d284:feb7:ee92:eff5:3fd6:7819',
          'port': 9443,
          'domain': 'gt7.lan',
        },
      ],
    });

    test('serves the port the hub named and dials every other device', () {
      final expansion = expandMesh(
        plan: plan,
        legacy: null,
        selfId: 'aaaa1111',
      );

      expect(expansion.expanded, isTrue);
      expect(expansion.listener!['name'], meshListenerName);
      expect(expansion.listener!['port'], 23333);
      expect(expansion.listener!['decryption'], 'server-half');
      expect(expansion.listener!['listen'], '::');

      // The device the answer belongs to is not dialled.
      expect(expansion.proxies, hasLength(1));
      final peer = expansion.proxies.single;
      expect(peer['name'], 'gt7');
      expect(peer['server'], '[2408:8256:d284:feb7:ee92:eff5:3fd6:7819]');
      expect(peer['port'], 9443);
      expect(peer['uuid'], 'uuid-value');
      expect(peer['encryption'], 'client-half');
      expect(peer['udp'], true);

      expect(expansion.rules, ['DOMAIN,gt7.lan,gt7']);
    });

    test('carries no mesh block over when the answer is whole', () {
      final rawConfig = <String, dynamic>{
        'mesh': {'directory-url': 'https://hub.example'},
        'proxies': [
          {'name': 'written', 'type': 'ss'},
        ],
        'rules': ['MATCH,DIRECT'],
      };

      applyMeshExpansion(
        rawConfig,
        expansion: expandMesh(plan: plan, legacy: null, selfId: 'aaaa1111'),
      );

      expect(rawConfig.containsKey('mesh'), isFalse);
      // The profile's own entries keep working behind the peers.
      expect(rawConfig['listeners'], hasLength(1));
      expect(rawConfig['proxies'], hasLength(2));
      expect(rawConfig['proxies'].last['name'], 'written');
      expect(rawConfig['rules'], ['DOMAIN,gt7.lan,gt7', 'MATCH,DIRECT']);
    });

    test('is left alone when the hub answered nothing and wrote nothing', () {
      final expansion = expandMesh(plan: null, legacy: null);
      expect(expansion.expanded, isFalse);
      expect(expansion.proxies, isEmpty);
    });

    test('reads the block a profile wrote itself', () {
      final expansion = expandMesh(
        plan: null,
        legacy: {
          'directory-id': 'aaaa1111',
          'proxy': {'uuid': 'self-uuid', 'encryption': 'self-client'},
          'listener': {'decryption': 'self-server'},
          'devices': [
            {
              'id': 'aaaa1111',
              'name': 'PC',
              'addr': '2408:8256:d284:feb7:485:945b:beed:f9fb',
            },
            {
              'id': 'bbbb2222',
              'name': 'gt7',
              'addr': '2408:8256:d284:feb7:ee92:eff5:3fd6:7819',
              'port': 9443,
            },
          ],
        },
      );

      expect(expansion.expanded, isTrue);
      expect(expansion.listener!['decryption'], 'self-server');
      expect(expansion.proxies, hasLength(1));
      expect(expansion.proxies.single['encryption'], 'self-client');
      expect(expansion.proxies.single['port'], 9443);
    });

    test('keeps the whole mesh when a device cannot be dialled', () {
      // A partial expansion would take the block away and cost the profile
      // every rule that reaches a peer, so the core is left to resolve them.
      final partial = parseMeshPlan({
        'port': 23333,
        'uuid': 'uuid-value',
        'encryption': 'client-half',
        'devices': [
          {
            'id': 'bbbb2222',
            'name': 'gt7',
            'addr': '2408:8256:d284:feb7:ee92:eff5:3fd6:7819',
          },
          {'id': 'cccc3333', 'name': 'no-address'},
        ],
      });

      final expansion = expandMesh(
        plan: partial,
        legacy: null,
        selfId: 'aaaa1111',
      );
      expect(expansion.expanded, isFalse);
      expect(expansion.warnings.join(' '), contains('no address'));
    });

    test('says so when nothing came with a user', () {
      final expansion = expandMesh(plan: null, legacy: {'devices': []});
      expect(expansion.expanded, isFalse);
      expect(expansion.warnings.join(' '), contains('no user'));
    });
  });
}
