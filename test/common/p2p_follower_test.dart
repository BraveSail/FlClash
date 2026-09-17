import 'dart:async';
import 'dart:io';

import 'package:fl_clash/common/p2p_follower.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeListener implements P2PListener {
  FakeListener({required this.address, required this.port});

  @override
  final String address;

  @override
  final int port;

  final controller = StreamController<P2PConnection>.broadcast();
  bool closed = false;

  @override
  Stream<P2PConnection> get connections => controller.stream;

  @override
  Future<void> close() async {
    closed = true;
    await controller.close();
  }
}

class FakeConnection implements P2PConnection {
  FakeConnection();

  final inputController = StreamController<List<int>>();
  final written = <int>[];
  bool closed = false;

  @override
  Stream<List<int>> get input => inputController.stream;

  @override
  void add(List<int> data) => written.addAll(data);

  @override
  Future<void> close() async {
    closed = true;
    if (!inputController.isClosed) {
      await inputController.close();
    }
  }
}

void main() {
  const peerKey = '100.64.0.5';
  const peers = [
    P2PPeer(
      key: peerKey,
      name: 'pc',
      addresses: ['[2409:8a55::1]:41641', '192.168.1.5:41641'],
      verifiedAddress: '[2409:8a55::1]:41641',
    ),
  ];

  test('peers parse from the status payload and skip self rows', () {
    final parsed = parseP2PPeers([
      {
        'proxy': 'ts',
        'peers': [
          {
            'name': 'pc.tailnet.ts.net.',
            'hostName': 'pc',
            'online': true,
            'tailscaleIPs': [peerKey],
            'addrs': ['[2409:8a55::1]:41641'],
            'curAddr': '[2409:8a55::1]:41641',
            'directVerified': true,
          },
          {
            'self': true,
            'tailscaleIPs': ['100.64.0.1'],
          },
          {'online': true},
        ],
      },
    ]);

    expect(parsed, hasLength(1));
    expect(parsed.single.key, peerKey);
    expect(parsed.single.name, 'pc.tailnet.ts.net.');
    expect(parsed.single.verifiedAddress, '[2409:8a55::1]:41641');
  });

  test('endpoints lose their port and unusable addresses are rejected', () {
    expect(hostFromEndpoint('[2409:8a55::1]:41641'), '2409:8a55::1');
    expect(hostFromEndpoint('2409:8a55::1'), '2409:8a55::1');
    expect(hostFromEndpoint('192.168.1.5:41641'), '192.168.1.5');
    expect(hostFromEndpoint('127.0.0.1:1'), isNull);
    expect(hostFromEndpoint('[fe80::1]:1'), isNull);
    expect(hostFromEndpoint('nonsense'), isNull);
    expect(hostFromEndpoint(''), isNull);
  });

  test('addresses are ordered verified, same-LAN, global, then v4', () {
    final prefix = ipv6Prefix64(
      InternetAddress.tryParse('2409:8a55:d0a4:5500:1:2:3:4')!,
    )!;
    final ordered = orderP2PAddresses(
      const P2PPeer(
        key: 'k',
        name: 'pc',
        addresses: [
          '[2409:8a55:ffff::9]:41641',
          '192.168.1.5:41641',
          '[2409:8a55:d0a4:5500:1:2:3:4]:41641',
        ],
        verifiedAddress: '[2409:8a55:aaaa::1]:41641',
      ),
      localPrefixes: {prefix},
    );

    expect(ordered, [
      '2409:8a55:aaaa::1',
      '2409:8a55:d0a4:5500:1:2:3:4',
      '2409:8a55:ffff::9',
      '192.168.1.5',
    ]);
  });

  test(
    'peer indexes are deterministic and leave index 1 to the local node',
    () {
      const peers = [
        P2PPeer(key: 'b', name: 'b', addresses: []),
        P2PPeer(key: 'a', name: 'a', addresses: []),
      ];
      expect(p2pPeerIndexes(peers), {'a': 2, 'b': 3});
      expect(p2pPeerIndexes(peers.reversed.toList()), {'a': 2, 'b': 3});
    },
  );

  test('followers bind a loopback per peer and forward to the peer', () async {
    final listeners = <FakeListener>[];
    final dials = <String>[];
    final outbound = FakeConnection();
    final inbound = FakeConnection();
    final follower = P2PPortFollower(
      bind: (address, port) async {
        final listener = FakeListener(address: address, port: port);
        listeners.add(listener);
        return listener;
      },
      dial: (host, port) async {
        dials.add('$host:$port');
        return outbound;
      },
      loadLocalPrefixes: () async => const {},
    );
    addTearDown(follower.close);
    addTearDown(inbound.close);
    addTearDown(outbound.close);

    await follower.update(ports: const [23333], peers: peers);

    expect(listeners, hasLength(1));
    expect(listeners.single.address, '127.0.0.2');
    expect(listeners.single.port, 23333);
    expect(follower.currentStatuses.single.localAddress, '127.0.0.2:23333');

    listeners.single.controller.add(inbound);
    await pumpEventQueue();
    expect(dials, ['2409:8a55::1:23333']);

    inbound.inputController.add([1, 2]);
    outbound.inputController.add([3]);
    await pumpEventQueue();
    expect(outbound.written, [1, 2]);
    expect(inbound.written, [3]);
  });

  test(
    'a failed dial records the error and unbinding closes listeners',
    () async {
      final listeners = <FakeListener>[];
      final follower = P2PPortFollower(
        bind: (address, port) async {
          final listener = FakeListener(address: address, port: port);
          listeners.add(listener);
          return listener;
        },
        dial: (host, port) async => throw StateError('unreachable'),
        loadLocalPrefixes: () async => const {},
      );
      addTearDown(follower.close);

      await follower.update(ports: const [23333], peers: peers);
      listeners.single.controller.add(FakeConnection());
      await pumpEventQueue();
      expect(
        follower.currentStatuses.single.lastError,
        contains('unreachable'),
      );

      await follower.update(ports: const [], peers: peers);
      expect(listeners.single.closed, isTrue);
      expect(follower.currentStatuses, isEmpty);
    },
  );
}
