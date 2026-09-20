import 'package:fl_clash/common/device_id.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the id is the same for the same machine and platform', () {
    final first = deviceIdFrom('linux', 'f94a5041458142b88dae7e2b379cb199');
    final again = deviceIdFrom('linux', 'f94a5041458142b88dae7e2b379cb199');
    expect(again, first);
    expect(first, matches(RegExp(r'^[0-9a-f]{12}$')));
  });

  test('the id separates two machines and two platforms', () {
    final machine = deviceIdFrom('linux', 'f94a5041458142b88dae7e2b379cb199');
    expect(deviceIdFrom('linux', 'other-machine-id'), isNot(machine));
    expect(
      deviceIdFrom('windows', 'f94a5041458142b88dae7e2b379cb199'),
      isNot(machine),
    );
  });

  test('a machine without an id computes none', () {
    expect(deviceIdFrom('linux', ''), '');
  });
}
