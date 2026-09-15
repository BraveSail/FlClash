// Regression tests for folding tailscale peers into the connections list.

import 'package:fl_clash/core/interface.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime(2026, 9, 15, 12);

  test('direct and relay transports map into chains chips', () {
    final infos = tailscalePeersToTrackerInfos({
      'proxy': 'ts',
      'peers': [
        {
          'name': 'laptop.tailnet.ts.net.',
          'hostName': 'laptop',
          'online': true,
          'active': true,
          'curAddr': '1.2.3.4:41641',
          'relay': '',
          'tailscaleIPs': ['100.64.0.5'],
          'txBytes': 100,
          'rxBytes': 200,
        },
        {
          'name': 'phone',
          'online': true,
          'active': false,
          'curAddr': '',
          'relay': 'tok',
          'tailscaleIPs': ['100.64.0.9'],
        },
      ],
    }, now);

    expect(infos, hasLength(2));
    final laptop = infos.first;
    expect(laptop.metadata.host, 'laptop.tailnet.ts.net'); // trailing dot trimmed
    expect(laptop.metadata.destinationIP, '100.64.0.5');
    expect(laptop.metadata.network, 'tailscale');
    expect(laptop.chains, contains('ts'));
    expect(laptop.chains, contains('direct 1.2.3.4:41641'));
    expect(laptop.upload, 100);
    expect(laptop.download, 200);
    expect(laptop.id, startsWith('tailscale:'));

    final phone = infos.last;
    expect(phone.chains, contains('derp via tok'));
    expect(phone.chains, contains('idle'));
  });

  test('offline peers carry the offline marker and no idle chip', () {
    final infos = tailscalePeersToTrackerInfos({
      'proxy': 'ts',
      'peers': [
        {
          'name': 'old-box',
          'online': false,
          'active': false,
          'tailscaleIPs': ['100.64.0.7'],
        },
      ],
    }, now);
    expect(infos, hasLength(1));
    expect(infos.single.chains, contains('offline'));
    expect(infos.single.chains, isNot(contains('idle')));
  });

  test('peers without name or ip are skipped; bad payload is safe', () {
    expect(
      tailscalePeersToTrackerInfos({
        'proxy': 'ts',
        'peers': [
          {'online': true},
          {'name': 'ok', 'tailscaleIPs': ['100.64.0.1']},
        ],
      }, now),
      hasLength(1),
    );
    expect(tailscalePeersToTrackerInfos({'proxy': 'ts'}, now), isEmpty);
    expect(tailscalePeersToTrackerInfos(const {}, now), isEmpty);
  });
}
