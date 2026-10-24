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

  // 设备列表的解析与注入已移进 core：app 只写 directory-url/token 和
  // directory-via-proxy，发现与展开由 mihomo 自己完成。

  group('hubProfileWatchUrl', () {
    test('names the id and the revision it already runs', () {
      expect(
        hubProfileWatchUrl('http://h/', 'abc', 'e1'),
        'http://h/profile/watch?id=abc&etag=e1',
      );
    });

    test('omits an empty revision', () {
      expect(
        hubProfileWatchUrl('http://h', 'abc', '  '),
        'http://h/profile/watch?id=abc',
      );
    });

    test('no id means no socket', () {
      expect(hubProfileWatchUrl('http://h', '   ', 'e1'), '');
      expect(hubProfileWatchUrl('', 'abc', 'e1'), '');
    });
  });

  group('hubSocketUrl', () {
    test('http becomes ws and https becomes wss', () {
      expect(hubSocketUrl('http://h:1/x'), 'ws://h:1/x');
      expect(hubSocketUrl('https://h/x'), 'wss://h/x');
    });

    test('a scheme-less value is left alone', () {
      expect(hubSocketUrl('h:1/x'), 'h:1/x');
    });
  });

  group('hubAuthHeaders', () {
    test('carries the token as a bearer, trimmed', () {
      expect(hubAuthHeaders(' secret '), {'Authorization': 'Bearer secret'});
    });
  });
}
