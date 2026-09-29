// The user and the encryption pair a shared mesh speaks are derived from the
// directory token, so that derivation stays in the core; this side carries
// what the hub answered instead.
library;

const meshDefaultPort = 23333;

const meshListenerName = 'mesh-in';

final _deviceName = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$');

class MeshDevice {
  const MeshDevice({
    required this.id,
    required this.name,
    required this.addr,
    required this.port,
    this.domain = '',
  });

  final String id;
  final String name;

  final String addr;

  final int port;
  final String domain;
}

class MeshPlan {
  const MeshPlan({
    required this.port,
    required this.uuid,
    required this.decryption,
    required this.encryption,
    required this.devices,
    required this.listed,
  });

  final int port;
  final String uuid;
  final String decryption;
  final String encryption;
  final List<MeshDevice> devices;

  final int listed;
}

class MeshExpansion {
  const MeshExpansion({
    required this.listener,
    required this.proxies,
    required this.rules,
    required this.warnings,
    required this.devices,
    required this.expanded,
  });

  final Map<String, dynamic>? listener;
  final List<Map<String, dynamic>> proxies;

  final List<String> rules;

  final List<String> warnings;
  final int devices;

  final bool expanded;
}

final _deviceDomain = RegExp(
  r'^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$',
);

final _deviceHost = RegExp(r'^[A-Za-z0-9._-]+$|^\[[0-9A-Fa-f:.]+\]$');

final _deviceIpv6 = RegExp(r'^[0-9A-Fa-f:]{2,}$');

MeshPlan? parseMeshPlan(Object? payload) {
  if (payload is! Map) {
    return null;
  }
  final uuid = readMeshValue(payload['uuid']);
  if (uuid == null) {
    return null;
  }
  final raw = payload['devices'];
  return MeshPlan(
    port: readMeshPort(payload['port']) ?? meshDefaultPort,
    uuid: uuid,
    decryption: readMeshValue(payload['decryption']) ?? '',
    encryption: readMeshValue(payload['encryption']) ?? '',
    devices: parseMeshDevices(raw),
    listed: raw is List ? raw.length : 0,
  );
}

List<MeshDevice> parseMeshDevices(Object? payload, {List<String>? warnings}) {
  if (payload is! List) {
    return const [];
  }
  final devices = <MeshDevice>[];
  final seenId = <String>{};
  final seenName = <String>{};
  for (final node in payload) {
    if (node is! Map) {
      continue;
    }
    final id = readMeshValue(node['id']);
    if (id == null || !_deviceName.hasMatch(id) || !seenId.add(id)) {
      continue;
    }
    var name = readMeshValue(node['name']) ?? '';
    if (!_deviceName.hasMatch(name) || seenName.contains(name)) {
      name = id;
    }
    final address = readMeshAddress(readMeshValue(node['addr']) ?? '');
    if (address == null) {
      warnings?.add('$name has no address this device can dial');
      continue;
    }
    seenName.add(name);
    final domain = (readMeshValue(node['domain']) ?? '').toLowerCase();
    devices.add(
      MeshDevice(
        id: id,
        name: name,
        addr: address.host,
        port: readMeshPort(node['port']) ?? address.port ?? meshDefaultPort,
        domain: _deviceDomain.hasMatch(domain) ? domain : '',
      ),
    );
  }
  devices.sort((a, b) => a.id.compareTo(b.id));
  return devices;
}

({String host, int? port})? readMeshAddress(String addr) {
  if (addr.startsWith('[')) {
    final end = addr.indexOf(']');
    if (end < 0) {
      return null;
    }
    final host = '[${addr.substring(1, end)}]';
    if (!_deviceHost.hasMatch(host)) {
      return null;
    }
    final tail = addr.substring(end + 1);
    if (tail.isEmpty) {
      return (host: host, port: null);
    }
    return tail.startsWith(':')
        ? (host: host, port: readMeshPort(tail.substring(1)))
        : null;
  }
  // A bare IPv6 address is all colons: the hub reports the address a peer is
  // reached at without brackets, and reading the last group as a port would
  // drop every such device.
  if (_deviceIpv6.hasMatch(addr)) {
    return (host: '[${addr.toLowerCase()}]', port: null);
  }
  if (!addr.contains(':')) {
    return _deviceHost.hasMatch(addr) ? (host: addr, port: null) : null;
  }
  final index = addr.lastIndexOf(':');
  final host = addr.substring(0, index);
  if (!_deviceHost.hasMatch(host)) {
    return null;
  }
  return (host: host, port: readMeshPort(addr.substring(index + 1)));
}

String? readMeshValue(Object? value) {
  final text = '${value ?? ''}'.trim();
  if (text.isEmpty || text.contains(_controlCharacters)) {
    return null;
  }
  return text;
}

int? readMeshPort(Object? value) {
  final port = value is int ? value : int.tryParse('${value ?? ''}'.trim());
  return port != null && port >= 1 && port <= 65535 ? port : null;
}

final _controlCharacters = RegExp(r'[\x00-\x1f\x7f]');

/// [plan] is the hub's answer; without one - a hub that could not be reached -
/// [legacy], the block the profile itself carries, is read for the parts it
/// spells out. The expansion is empty unless the whole mesh could be carried
/// over, because taking the block away for a partial one costs the profile
/// every rule that reaches a peer; a partial mesh is left for the core.
MeshExpansion expandMesh({
  required MeshPlan? plan,
  required Object? legacy,
  String selfId = '',
}) {
  final warnings = <String>[];
  final uuid = plan?.uuid ?? _legacyValue(legacy, ['proxy', 'uuid']);
  final decryption =
      plan?.decryption ?? _legacyValue(legacy, ['listener', 'decryption']);
  final encryption =
      plan?.encryption ?? _legacyValue(legacy, ['proxy', 'encryption']);
  final named = plan == null ? _legacyField(legacy, 'devices') : null;
  final devices = plan?.devices ?? parseMeshDevices(named, warnings: warnings);
  final listed = plan?.listed ?? (named is List ? named.length : 0);
  final unaddressable = listed - devices.length;
  if (unaddressable > 0) {
    warnings.add(
      '$unaddressable device(s) carry no address this device can dial; the '
      'core keeps resolving them',
    );
  }
  if (uuid.isEmpty) {
    warnings.add('no user came with the mesh, so nothing can be dialled');
  }
  if (devices.isEmpty) {
    warnings.add('no device came with an address to dial');
  }
  if (uuid.isEmpty || devices.isEmpty || unaddressable > 0) {
    return MeshExpansion(
      listener: null,
      proxies: const [],
      rules: const [],
      warnings: warnings,
      devices: devices.length,
      expanded: false,
    );
  }

  final directoryId = plan == null
      ? _legacyValue(legacy, ['directory-id'])
      : '';
  final self = selfId.isNotEmpty ? selfId : directoryId;
  final peers = <MeshDevice>[
    for (final device in devices)
      if (self.isEmpty || device.id != self) device,
  ];

  final proxies = <Map<String, dynamic>>[];
  final rules = <String>[];
  for (final peer in peers) {
    proxies.add({
      'name': peer.name,
      'type': 'vless',
      'server': peer.addr,
      'port': peer.port,
      'uuid': uuid,
      if (encryption.isNotEmpty) 'encryption': encryption,
      'udp': true,
    });
    if (peer.domain.isNotEmpty) {
      rules.add('DOMAIN,${peer.domain},${peer.name}');
    }
  }
  return MeshExpansion(
    listener: <String, dynamic>{
      'name': meshListenerName,
      'type': 'vless',
      'listen': '::',
      'port': plan?.port ?? meshDefaultPort,
      'users': [
        {'uuid': uuid},
      ],
      if (decryption.isNotEmpty) 'decryption': decryption,
    },
    proxies: proxies,
    rules: rules,
    warnings: warnings,
    devices: devices.length,
    expanded: true,
  );
}

/// Every section is rebuilt rather than edited in place: a section can arrive
/// typed as narrowly as `List<Map<String, String>>`, and inserting into one of
/// those throws.
void applyMeshExpansion(
  Map<String, dynamic> rawConfig, {
  required MeshExpansion expansion,
}) {
  if (!expansion.expanded) {
    return;
  }
  rawConfig.remove('mesh');
  final listener = expansion.listener;
  if (listener != null) {
    rawConfig['listeners'] = [
      listener,
      if (rawConfig['listeners'] is List) ...rawConfig['listeners'] as List,
    ];
  }
  if (expansion.proxies.isNotEmpty) {
    rawConfig['proxies'] = [
      ...expansion.proxies,
      if (rawConfig['proxies'] is List) ...rawConfig['proxies'] as List,
    ];
  }
  if (expansion.rules.isNotEmpty) {
    rawConfig['rules'] = [
      ...expansion.rules,
      if (rawConfig['rules'] is List) ...rawConfig['rules'] as List,
    ];
  }
}

Object? _legacyField(Object? legacy, String key) {
  return legacy is Map ? legacy[key] : null;
}

String _legacyValue(Object? legacy, List<String> path) {
  Object? value = legacy;
  for (final key in path) {
    value = _legacyField(value, key);
  }
  return readMeshValue(value) ?? '';
}
