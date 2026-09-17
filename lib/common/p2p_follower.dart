import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// One remote tailnet peer as the core's `getTailscaleStatus` reported it.
@immutable
class P2PPeer {
  const P2PPeer({
    required this.key,
    required this.name,
    required this.addresses,
    this.verifiedAddress,
  });

  final String key;
  final String name;

  /// Endpoints the peer currently advertises, `host:port` or `[host]:port`.
  final List<String> addresses;

  /// The peer's current path when the core reports a verified direct one.
  final String? verifiedAddress;
}

@immutable
class P2PMappingStatus {
  const P2PMappingStatus({
    required this.port,
    required this.peerIndex,
    required this.peerName,
    this.targetAddress,
    this.lastError,
    this.activeConnections = 0,
  });

  final int port;
  final int peerIndex;
  final String peerName;
  final String? targetAddress;
  final String? lastError;
  final int activeConnections;

  String get localAddress => '127.0.0.$peerIndex:$port';

  P2PMappingStatus copyWith({
    String? targetAddress,
    Object? lastError = _unset,
    int? activeConnections,
  }) {
    return P2PMappingStatus(
      port: port,
      peerIndex: peerIndex,
      peerName: peerName,
      targetAddress: targetAddress ?? this.targetAddress,
      lastError: identical(lastError, _unset)
          ? this.lastError
          : lastError as String?,
      activeConnections: activeConnections ?? this.activeConnections,
    );
  }
}

const _unset = Object();

abstract interface class P2PListener {
  String get address;

  int get port;

  Stream<P2PConnection> get connections;

  Future<void> close();
}

abstract interface class P2PConnection {
  Stream<List<int>> get input;

  void add(List<int> data);

  Future<void> close();
}

typedef P2PListenerBinder =
    Future<P2PListener> Function(String address, int port);
typedef P2PConnectionDialer =
    Future<P2PConnection> Function(String host, int port);
typedef P2PPrefixLoader = Future<Set<String>> Function();

/// Loopback indexes are 1-based and index 1 is the local node.
const int p2pFirstPeerIndex = 2;
const int p2pMaxPeerIndex = 254;

/// Peers parsed from the core's tailscale status payloads.
List<P2PPeer> parseP2PPeers(List<dynamic> statuses) {
  final peers = <P2PPeer>[];
  for (final status in statuses) {
    if (status is! Map) {
      continue;
    }
    final rawPeers = status['peers'];
    if (rawPeers is! List) {
      continue;
    }
    for (final rawPeer in rawPeers) {
      if (rawPeer is! Map) {
        continue;
      }
      final peer = Map<String, Object?>.from(rawPeer);
      if (peer['self'] == true) {
        continue;
      }
      final key = _peerKey(peer);
      if (key == null) {
        continue;
      }
      final name = peer['name'] ?? peer['hostName'] ?? key;
      peers.add(
        P2PPeer(
          key: key,
          name: name.toString(),
          addresses:
              (peer['addrs'] as List?)?.whereType<String>().toList(
                growable: false,
              ) ??
              const <String>[],
          verifiedAddress: peer['directVerified'] == true
              ? peer['curAddr'] as String?
              : null,
        ),
      );
    }
  }
  return peers;
}

/// Deterministic loopback index per peer, so every device agrees on which
/// `127.0.0.<index>` reaches which peer.
Map<String, int> p2pPeerIndexes(List<P2PPeer> peers) {
  final keys = peers.map((peer) => peer.key).toSet().toList()..sort();
  final indexes = <String, int>{};
  for (var i = 0; i < keys.length; i++) {
    final index = p2pFirstPeerIndex + i;
    if (index > p2pMaxPeerIndex) {
      break;
    }
    indexes[keys[i]] = index;
  }
  return indexes;
}

/// Addresses to try for [peer], best first: the verified direct path, then
/// IPv6 on the same /64 as a local interface, then other IPv6, then IPv4.
List<String> orderP2PAddresses(
  P2PPeer peer, {
  required Set<String> localPrefixes,
}) {
  final verified = peer.verifiedAddress == null
      ? null
      : hostFromEndpoint(peer.verifiedAddress!);
  final sameLan = <String>[];
  final globalV6 = <String>[];
  final others = <String>[];
  final seen = <String>{};
  for (final endpoint in peer.addresses) {
    final host = hostFromEndpoint(endpoint);
    if (host == null || host == verified || !seen.add(host)) {
      continue;
    }
    final address = InternetAddress.tryParse(host);
    if (address == null) {
      continue;
    }
    if (address.type != InternetAddressType.IPv4) {
      final prefix = ipv6Prefix64(address);
      (prefix != null && localPrefixes.contains(prefix) ? sameLan : globalV6)
          .add(host);
    } else {
      others.add(host);
    }
  }
  return [?verified, ...sameLan, ...globalV6, ...others];
}

/// Strips the port from one endpoint and rejects addresses that cannot be
/// dialed as they are (loopback, link-local, malformed).
String? hostFromEndpoint(String endpoint) {
  var value = endpoint.trim();
  if (value.isEmpty) {
    return null;
  }
  if (value.startsWith('[')) {
    final end = value.indexOf(']');
    if (end <= 1) {
      return null;
    }
    value = value.substring(1, end);
  } else if (':'.allMatches(value).length == 1) {
    value = value.substring(0, value.indexOf(':'));
  }
  final address = InternetAddress.tryParse(value);
  if (address == null || address.isLoopback || address.isLinkLocal) {
    return null;
  }
  return address.address;
}

/// The /64 group of an IPv6 address as raw hex, for same-LAN preference.
String? ipv6Prefix64(InternetAddress address) {
  final raw = address.rawAddress;
  if (address.type == InternetAddressType.IPv4 || raw.length != 16) {
    return null;
  }
  return raw
      .sublist(0, 8)
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
}

Future<Set<String>> localIPv6Prefixes() async {
  final prefixes = <String>{};
  final interfaces = await NetworkInterface.list(includeLoopback: false);
  for (final interface in interfaces) {
    for (final address in interface.addresses) {
      final prefix = ipv6Prefix64(address);
      if (prefix != null) {
        prefixes.add(prefix);
      }
    }
  }
  return prefixes;
}

/// Symmetric peer port follower: for every peer and port it accepts
/// connections on `127.0.0.<peerIndex>:<port>` and forwards them to the
/// peer's current address, resolved per connection.
class P2PPortFollower {
  P2PPortFollower({
    P2PListenerBinder? bind,
    P2PConnectionDialer? dial,
    P2PPrefixLoader? loadLocalPrefixes,
    this.connectTimeout = const Duration(seconds: 10),
  }) : _bind = bind ?? _bindLoopback,
       _dial = dial ?? _dialHost,
       _loadLocalPrefixes = loadLocalPrefixes ?? localIPv6Prefixes;

  final P2PListenerBinder _bind;
  final P2PConnectionDialer _dial;
  final P2PPrefixLoader _loadLocalPrefixes;
  final Duration connectTimeout;

  final _controller = StreamController<List<P2PMappingStatus>>.broadcast();
  final _listeners = <String, P2PListener>{};
  final _statuses = <String, P2PMappingStatus>{};

  List<int> _ports = const [];
  List<P2PPeer> _peers = const [];
  bool _closed = false;

  Stream<List<P2PMappingStatus>> get statuses => _controller.stream;

  List<P2PMappingStatus> get currentStatuses => _sortedStatuses();

  Future<void> update({
    required List<int> ports,
    required List<P2PPeer> peers,
  }) async {
    if (_closed) {
      return;
    }
    _ports = ports.toSet().toList()..sort();
    _peers = List.unmodifiable(peers);
    final desired = await _desiredBindings();
    for (final key in _listeners.keys.toList()) {
      if (!desired.containsKey(key)) {
        final listener = _listeners.remove(key)!;
        _statuses.remove(key);
        await listener.close();
      }
    }
    for (final entry in desired.entries) {
      if (_listeners.containsKey(entry.key)) {
        continue;
      }
      final target = entry.value;
      try {
        final listener = await _bind(target.address, target.port);
        _listeners[entry.key] = listener;
        _statuses[entry.key] = target.status;
        listener.connections.listen(
          (connection) => unawaited(_forward(target, connection)),
          onError: (Object error) {
            _recordError(entry.key, error);
          },
        );
      } catch (error) {
        _statuses[entry.key] = target.status.copyWith(lastError: '$error');
      }
    }
    _emit();
  }

  Future<void> close() async {
    _closed = true;
    for (final listener in _listeners.values) {
      await listener.close();
    }
    _listeners.clear();
    _statuses.clear();
    await _controller.close();
  }

  Future<Map<String, _Binding>> _desiredBindings() async {
    final indexes = p2pPeerIndexes(_peers);
    final bindings = <String, _Binding>{};
    for (final peer in _peers) {
      final index = indexes[peer.key];
      if (index == null) {
        continue;
      }
      for (final port in _ports) {
        final key = '$index:$port';
        bindings[key] = _Binding(
          key: key,
          address: '127.0.0.$index',
          port: port,
          peer: peer,
          status: P2PMappingStatus(
            port: port,
            peerIndex: index,
            peerName: peer.name,
          ),
        );
      }
    }
    return bindings;
  }

  Future<void> _forward(_Binding binding, P2PConnection inbound) async {
    _updateStatus(
      binding.key,
      (status) =>
          status.copyWith(activeConnections: status.activeConnections + 1),
    );
    P2PConnection? outbound;
    try {
      final target = await _resolveTarget(binding);
      if (target == null) {
        throw StateError('no reachable address for ${binding.peer.name}');
      }
      outbound = await _dial(target, binding.port).timeout(connectTimeout);
      _updateStatus(
        binding.key,
        (status) => status.copyWith(targetAddress: target, lastError: null),
      );
      final connection = outbound;
      await Future.wait([
        _copy(inbound.input, connection),
        _copy(connection.input, inbound),
      ], eagerError: false);
    } catch (error) {
      _recordError(binding.key, error);
    } finally {
      await inbound.close();
      await outbound?.close();
      _updateStatus(
        binding.key,
        (status) =>
            status.copyWith(activeConnections: status.activeConnections - 1),
      );
    }
  }

  Future<String?> _resolveTarget(_Binding binding) async {
    final prefixes = await _loadLocalPrefixes();
    final addresses = orderP2PAddresses(
      _peers.firstWhere(
        (peer) => peer.key == binding.peer.key,
        orElse: () => binding.peer,
      ),
      localPrefixes: prefixes,
    );
    return addresses.isEmpty ? null : addresses.first;
  }

  Future<void> _copy(Stream<List<int>> input, P2PConnection output) async {
    await for (final data in input) {
      output.add(data);
    }
  }

  void _recordError(String key, Object error) {
    _updateStatus(key, (status) => status.copyWith(lastError: '$error'));
  }

  void _updateStatus(
    String key,
    P2PMappingStatus Function(P2PMappingStatus status) update,
  ) {
    final status = _statuses[key];
    if (status == null) {
      return;
    }
    _statuses[key] = update(status);
    _emit();
  }

  List<P2PMappingStatus> _sortedStatuses() {
    final statuses = _statuses.values.toList()
      ..sort((a, b) {
        final byPeer = a.peerIndex.compareTo(b.peerIndex);
        return byPeer != 0 ? byPeer : a.port.compareTo(b.port);
      });
    return statuses;
  }

  void _emit() {
    if (!_controller.isClosed) {
      _controller.add(_sortedStatuses());
    }
  }
}

class _Binding {
  const _Binding({
    required this.key,
    required this.address,
    required this.port,
    required this.peer,
    required this.status,
  });

  final String key;
  final String address;
  final int port;
  final P2PPeer peer;
  final P2PMappingStatus status;
}

String? _peerKey(Map<String, Object?> peer) {
  final id = peer['id'];
  if (id != null && id.toString().isNotEmpty) {
    return id.toString();
  }
  final ips = (peer['tailscaleIPs'] as List?)?.whereType<String>();
  if (ips != null && ips.isNotEmpty) {
    return ips.first;
  }
  final name = peer['hostName'] ?? peer['name'];
  if (name is String && name.isNotEmpty) {
    return name;
  }
  return null;
}

Future<P2PListener> _bindLoopback(String address, int port) async {
  final server = await ServerSocket.bind(address, port, shared: false);
  return _IoListener(server);
}

Future<P2PConnection> _dialHost(String host, int port) async {
  // The connection wrapper takes ownership of the socket and closes it.
  // ignore: close_sinks
  final socket = await Socket.connect(host, port);
  return _IoConnection(socket);
}

class _IoListener implements P2PListener {
  _IoListener(this._server);

  final ServerSocket _server;

  @override
  String get address => _server.address.address;

  @override
  int get port => _server.port;

  @override
  Stream<P2PConnection> get connections =>
      _server.map((socket) => _IoConnection(socket));

  @override
  Future<void> close() => _server.close();
}

class _IoConnection implements P2PConnection {
  _IoConnection(this._socket);

  final Socket _socket;

  @override
  Stream<List<int>> get input => _socket;

  @override
  void add(List<int> data) => _socket.add(data);

  @override
  Future<void> close() async {
    await _socket.close();
    _socket.destroy();
  }
}
