import 'package:fl_clash/common/common.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('applyDirectoryId names the directory entry this device runs', () {
    final rawConfig = <String, dynamic>{
      'proxies': [
        {'name': 'peer-directory', 'type': 'peer-directory', 'id': 'shared'},
        {'name': 'pc', 'type': 'tailnet-peer', 'peer': 'pc'},
        'not a proxy',
      ],
    };

    applyDirectoryId(rawConfig, ' gt7 ');

    final proxies = rawConfig['proxies'] as List;
    expect((proxies[0] as Map)['id'], 'gt7');
    expect((proxies[1] as Map).containsKey('id'), isFalse);
  });

  test('applyDirectoryId leaves the profile alone without a name', () {
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

    applyDirectoryId(rawConfig, 'pc');

    expect(rawConfig.keys, ['rules']);
  });
}
