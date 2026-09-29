import 'package:fl_clash/common/common.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('applyDirectoryId names the directory entry this device runs', () {
    final rawConfig = <String, dynamic>{
      'proxies': [
        {'name': 'peer-directory', 'type': 'peer-directory', 'id': 'shared'},
        {
          'name': 'pc',
          'type': 'tailnet-peer',
          'peer': 'pc',
          'directory-url': 'https://directory.example',
        },
        {'name': 'plain', 'type': 'tailnet-peer', 'peer': 'plain'},
        'not a proxy',
      ],
    };

    applyDirectoryId(rawConfig, ' a3f8b2c91d04 ');

    final proxies = rawConfig['proxies'] as List;
    expect((proxies[0] as Map)['id'], 'a3f8b2c91d04');
    expect((proxies[1] as Map)['directory-id'], 'a3f8b2c91d04');
    expect((proxies[1] as Map).containsKey('id'), isFalse);
    expect((proxies[2] as Map).containsKey('directory-id'), isFalse);
  });

  test('applyDirectoryId leaves the mesh block alone', () {
    final rawConfig = <String, dynamic>{
      'mesh': {
        'directory-url': 'https://directory.example',
        'devices': [
          {'name': 'pc'},
          {'name': 'gt7'},
        ],
      },
      'proxies': <dynamic>[],
    };

    applyDirectoryId(rawConfig, 'a3f8b2c91d04');

    // The app expands the block into plain outbounds and never writes it back,
    // so naming this device here would have nothing to serve.
    expect((rawConfig['mesh'] as Map).containsKey('directory-id'), isFalse);
    expect((rawConfig['mesh'] as Map)['devices'], isA<List>());
  });

  test('applyDirectoryId carries the name and system to every entry', () {
    final rawConfig = <String, dynamic>{
      'proxies': [
        {'name': 'peer-directory', 'type': 'peer-directory', 'id': 'shared'},
        {
          'name': 'pc',
          'type': 'tailnet-peer',
          'peer': 'pc',
          'directory-url': 'https://directory.example',
        },
        {'name': 'plain', 'type': 'tailnet-peer', 'peer': 'plain'},
      ],
    };

    applyDirectoryId(
      rawConfig,
      'a3f8b2c91d04',
      name: ' 小明的手机 ',
      os: 'Android 14',
    );

    final proxies = rawConfig['proxies'] as List;
    // The entries that report this device carry it; one that reports nothing
    // (no directory of its own) is not given anything to say.
    expect((proxies[0] as Map)['hostname'], '小明的手机');
    expect((proxies[0] as Map)['os'], 'Android 14');
    expect((proxies[1] as Map)['hostname'], '小明的手机');
    expect((proxies[1] as Map)['os'], 'Android 14');
    expect((proxies[2] as Map).containsKey('hostname'), isFalse);
    expect((proxies[2] as Map).containsKey('os'), isFalse);
  });

  test('applyDirectoryId sends nothing about a device that read nothing', () {
    final rawConfig = <String, dynamic>{
      'proxies': [
        {'name': 'peer-directory', 'type': 'peer-directory', 'id': 'shared'},
      ],
    };

    applyDirectoryId(rawConfig, 'a3f8b2c91d04');

    final proxy = (rawConfig['proxies'] as List).first as Map;
    expect(proxy.containsKey('hostname'), isFalse);
    expect(proxy.containsKey('os'), isFalse);
  });

  test('applyDirectoryId leaves the profile alone without an id', () {
    final rawConfig = <String, dynamic>{
      'proxies': [
        {'name': 'peer-directory', 'type': 'peer-directory', 'id': 'shared'},
      ],
    };

    applyDirectoryId(rawConfig, '  ');

    expect(((rawConfig['proxies'] as List).first as Map)['id'], 'shared');
  });

  test('applyDirectoryId tolerates a profile without proxies', () {
    final rawConfig = <String, dynamic>{'rules': <String>[]};

    applyDirectoryId(rawConfig, 'a3f8b2c91d04');

    expect(rawConfig.keys, ['rules']);
  });
}
