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

  group('applyHubConnection', () {
    test('points the mesh block at the hub', () {
      final rawConfig = <String, dynamic>{
        'mesh': {
          'proxy': {'type': 'vless'},
          'devices': [
            {'name': 'pc'},
          ],
        },
      };

      applyHubConnection(rawConfig, 'https://hub.example/', ' secret ');

      final mesh = rawConfig['mesh'] as Map;
      expect(mesh['directory-url'], 'https://hub.example');
      expect(mesh['directory-token'], 'secret');
      expect(mesh['devices'], isA<List>());
    });

    test('the settings win over the values the profile carries', () {
      final rawConfig = <String, dynamic>{
        'mesh': {
          'directory-url': 'https://own.example',
          'directory-token': 'own-token',
        },
      };

      applyHubConnection(rawConfig, 'https://hub.example', 'secret');

      final mesh = rawConfig['mesh'] as Map;
      expect(mesh['directory-url'], 'https://hub.example');
      expect(mesh['directory-token'], 'secret');
    });

    test('leaves a profile without a mesh block alone', () {
      final rawConfig = <String, dynamic>{'proxies': <dynamic>[]};

      applyHubConnection(rawConfig, 'https://hub.example', 'secret');

      expect(rawConfig.keys, ['proxies']);
    });

    test('does nothing while the hub is not configured', () {
      final rawConfig = <String, dynamic>{'mesh': <String, dynamic>{}};

      applyHubConnection(rawConfig, '', 'secret');
      applyHubConnection(rawConfig, 'https://hub.example', '');

      expect(rawConfig['mesh'], isEmpty);
    });
  });

  group('hubAuthHeaders', () {
    test('sends the token as a bearer credential', () {
      expect(hubAuthHeaders(' secret '), {'Authorization': 'Bearer secret'});
    });
  });

  group('hubDevicesUrl', () {
    test('addresses the device list on the hub origin', () {
      expect(
        hubDevicesUrl('https://hub.example/'),
        'https://hub.example/api/devices',
      );
      expect(hubDevicesUrl(''), '');
    });
  });

  group('parseHubDevices', () {
    test('reads the name, the id and the port of every device', () {
      final devices = parseHubDevices({
        'nodes': [
          {'id': 'bbbb2222', 'hostname': 'gt7', 'port': 9443},
          {
            'id': 'aaaa1111',
            'alias': 'PC',
            'hostname': 'desktop',
            'port': 8443,
          },
        ],
      });

      // Ordered by id, so every device of the mesh expands the same list in
      // the same order.
      expect(devices.map((d) => d.id), ['aaaa1111', 'bbbb2222']);
      expect(devices.first.name, 'PC');
      expect(devices.first.port, 8443);
      expect(devices.last.name, 'gt7');
    });

    test('prefers the alias, then the host name, then the id', () {
      final devices = parseHubDevices({
        'nodes': [
          {'id': 'aaaa1111', 'alias': 'PC', 'hostname': 'desktop'},
          {'id': 'bbbb2222', 'hostname': 'gt7'},
          {'id': 'cccc3333'},
        ],
      });

      expect(devices.map((d) => d.name), ['PC', 'gt7', 'cccc3333']);
    });

    test('falls back to the id for a name the core would refuse', () {
      final devices = parseHubDevices({
        'nodes': [
          {'id': 'aaaa1111', 'hostname': 'two words'},
          {'id': 'bbbb2222', 'hostname': 'x' * 64},
        ],
      });

      expect(devices.map((d) => d.name), ['aaaa1111', 'bbbb2222']);
    });

    test('keeps two devices from sharing one name', () {
      final devices = parseHubDevices({
        'nodes': [
          {'id': 'aaaa1111', 'hostname': 'pc'},
          {'id': 'bbbb2222', 'hostname': 'pc'},
        ],
      });

      expect(devices.map((d) => d.name), ['pc', 'bbbb2222']);
    });

    test('drops a record no client could ask about', () {
      final devices = parseHubDevices({
        'nodes': [
          {'hostname': 'no id'},
          {'id': 'bad id'},
          {'id': 'aaaa1111', 'hostname': 'pc'},
        ],
      });

      expect(devices.map((d) => d.id), ['aaaa1111']);
    });

    test(
      'keeps a device without a usable port and answers an unreadable payload',
      () {
        final devices = parseHubDevices({
          'nodes': [
            {'id': 'aaaa1111', 'port': 70000},
            {'id': 'bbbb2222'},
          ],
        });

        expect(devices.map((d) => d.port), [0, 0]);
        expect(parseHubDevices(null), isEmpty);
        expect(parseHubDevices({'nodes': 'nope'}), isEmpty);
      },
    );
  });

  group('applyHubDevices', () {
    test('writes the list and the flag the core expands from', () {
      final rawConfig = <String, dynamic>{
        'mesh': <String, dynamic>{'directory-url': 'https://hub.example'},
      };

      applyHubDevices(
        rawConfig,
        devices: const [
          HubDevice(name: 'PC', id: 'aaaa1111'),
          HubDevice(name: 'gt7', id: 'bbbb2222', port: 9443),
        ],
      );

      final mesh = rawConfig['mesh'] as Map;
      expect(mesh['directory-resolved'], isTrue);
      expect(mesh['devices'], [
        {'name': 'PC', 'id': 'aaaa1111'},
        {'name': 'gt7', 'id': 'bbbb2222', 'port': 9443},
      ]);
      expect(mesh.containsKey('directory-proxy'), isFalse);
    });

    test('an empty list is still a resolved list', () {
      final rawConfig = <String, dynamic>{
        'mesh': <String, dynamic>{'directory-url': 'https://hub.example'},
      };

      applyHubDevices(rawConfig, devices: const []);

      final mesh = rawConfig['mesh'] as Map;
      // The core takes this as "the hub holds no device" and reads nothing
      // while it parses, rather than failing the start on a blocked network.
      expect(mesh['directory-resolved'], isTrue);
      expect(mesh['devices'], isEmpty);
    });

    test('carries the proxy the runtime requests go through', () {
      final rawConfig = <String, dynamic>{
        'mesh': <String, dynamic>{'directory-url': 'https://hub.example'},
      };

      applyHubDevices(
        rawConfig,
        devices: const [HubDevice(name: 'PC', id: 'aaaa1111')],
        directoryProxy: 'http://127.0.0.1:7890',
      );

      expect(
        (rawConfig['mesh'] as Map)['directory-proxy'],
        'http://127.0.0.1:7890',
      );
    });

    test('leaves a profile without a mesh block alone', () {
      final rawConfig = <String, dynamic>{'proxies': <dynamic>[]};

      applyHubDevices(
        rawConfig,
        devices: const [HubDevice(name: 'PC', id: 'aaaa1111')],
      );

      expect(rawConfig.keys, ['proxies']);
    });
  });
}
