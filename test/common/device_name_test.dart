import 'package:fl_clash/common/common.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the name the owner typed outranks the model it was built on', () {
    expect(deviceName('我的手机', 'Xiaomi', '13', ''), '我的手机');
    expect(deviceName('  我的手机  ', 'Xiaomi', '13', ''), '我的手机');
    expect(deviceName(null, 'Xiaomi', '13', ''), 'Xiaomi 13');
    expect(deviceName('  ', 'Xiaomi', '13', ''), 'Xiaomi 13');
    expect(deviceName('', 'Xiaomi', '', ''), 'Xiaomi');
  });

  test('a device that says nothing about itself yields nothing', () {
    expect(deviceName(null, '', '', ''), '');
    expect(deviceName(null, '', '  ', '  '), '');
  });

  test(
    'the desktop host name is the fallback where there is no android one',
    () {
      expect(deviceName(null, '', '', 'DESKTOP-ABC'), 'DESKTOP-ABC');
      expect(deviceName(null, '', '', ' DESKTOP-ABC '), 'DESKTOP-ABC');
    },
  );

  test('the system reads as a name and a version', () {
    expect(deviceOs('Android', '14'), 'Android 14');
    expect(deviceOs('Windows', '11', flavour: '24H2'), 'Windows 11 24H2');
    expect(deviceOs('macOS', '15.2.0'), 'macOS 15.2.0');
    expect(deviceOs('Ubuntu 24.04 LTS', ''), 'Ubuntu 24.04 LTS');
  });

  test('an unknown part of the system is left out, not shown as empty', () {
    expect(deviceOs('Android', ''), 'Android');
    expect(deviceOs('', '', flavour: '24H2'), '24H2');
    expect(deviceOs('', ''), '');
  });
}
