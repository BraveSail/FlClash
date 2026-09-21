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
}
