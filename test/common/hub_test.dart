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

  group('splitHubLink', () {
    test('takes the token out of the link and leaves the address bare', () {
      // The address handed on must have no query: the core appends its own
      // path to it, and a query in the middle corrupts that.
      final split = splitHubLink('https://hub.example/?token=secret');
      expect(split.url, 'https://hub.example/');
      expect(split.token, 'secret');
    });

    test('keeps other parameters while removing only the token', () {
      final split = splitHubLink('https://hub.example/?id=pc&token=secret');
      expect(split.token, 'secret');
      expect(split.url, contains('id=pc'));
      expect(split.url, isNot(contains('token=')));
    });

    test('uses the configured token when the link carries none', () {
      final split = splitHubLink(
        'https://hub.example',
        fallbackToken: ' stored ',
      );
      expect(split.url, 'https://hub.example');
      expect(split.token, 'stored');
    });

    test('a link with a token wins over the stored one', () {
      final split = splitHubLink(
        'https://hub.example/?token=fresh',
        fallbackToken: 'stored',
      );
      expect(split.token, 'fresh');
    });

    test('leaves an address it cannot parse alone', () {
      final split = splitHubLink('not a url', fallbackToken: 'stored');
      expect(split.url, 'not a url');
      expect(split.token, 'stored');
    });

    test('an empty link keeps the configured token and asks for nothing', () {
      final split = splitHubLink('  ', fallbackToken: 'stored');
      expect(split.url, '');
      expect(split.token, 'stored');
    });

    test('trims the token it takes out of the link', () {
      expect(splitHubLink('https://hub.example/?token=%20secret%20').token,
          'secret');
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

    test('reads the domain a rule reaches the device by', () {
      final devices = parseHubDevices({
        'nodes': [
          {'id': 'aaaa1111', 'hostname': 'pc', 'domain': 'pc.lan'},
          {'id': 'bbbb2222', 'hostname': 'gt7'},
        ],
      });

      expect(devices.first.domain, 'pc.lan');
      // A device the hub holds no domain for keeps its place: the core writes
      // no rule for it, and it is still reached by its name.
      expect(devices.last.domain, isEmpty);
    });

    test('normalizes a domain and drops one the core would refuse', () {
      final devices = parseHubDevices({
        'nodes': [
          {'id': 'aaaa1111', 'domain': 'PC.LAN'},
          {'id': 'bbbb2222', 'domain': 'has spaces'},
          {'id': 'cccc3333', 'domain': '-bad.example'},
        ],
      });

      // The core matches the name a connection asked for, and a domain is
      // case-insensitive: lower case here is what makes the rule match.
      expect(devices.first.domain, 'pc.lan');
      // A domain only decides which device a name reaches, so a bad one costs
      // the device its domain, not its place in the mesh.
      expect(devices[1].domain, isEmpty);
      expect(devices[2].domain, isEmpty);
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

    test('writes the domain so the core can write the rule from it', () {
      final rawConfig = <String, dynamic>{
        'mesh': <String, dynamic>{'directory-url': 'https://hub.example'},
      };

      applyHubDevices(
        rawConfig,
        devices: const [
          HubDevice(name: 'PC', id: 'aaaa1111', domain: 'pc.lan'),
          HubDevice(name: 'gt7', id: 'bbbb2222', domain: 'gt7.lan'),
        ],
      );

      // The profile writes no rule for a device: the core writes one per
      // domain here, so a device renamed on the dashboard never leaves a rule
      // pointing at nothing.
      expect((rawConfig['mesh'] as Map)['devices'], [
        {'name': 'PC', 'id': 'aaaa1111', 'domain': 'pc.lan'},
        {'name': 'gt7', 'id': 'bbbb2222', 'domain': 'gt7.lan'},
      ]);
    });

    test('leaves the domain out when the hub holds none', () {
      final rawConfig = <String, dynamic>{
        'mesh': <String, dynamic>{'directory-url': 'https://hub.example'},
      };

      applyHubDevices(
        rawConfig,
        devices: const [HubDevice(name: 'PC', id: 'aaaa1111')],
      );

      expect((rawConfig['mesh'] as Map)['devices'], [
        {'name': 'PC', 'id': 'aaaa1111'},
      ]);
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
