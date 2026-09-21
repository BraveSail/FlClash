/// The Hub hands each device its own profile; both halves name it.
bool isHubEnabled(String hubUrl, String hubToken) {
  return hubUrl.trim().isNotEmpty && hubToken.trim().isNotEmpty;
}

String normalizeHubUrl(String hubUrl) {
  var url = hubUrl.trim();
  while (url.endsWith('/')) {
    url = url.substring(0, url.length - 1);
  }
  return url;
}

String hubProfileUrl(String hubUrl, String deviceId) {
  final base = normalizeHubUrl(hubUrl);
  if (base.isEmpty) {
    return '';
  }
  final id = deviceId.trim();
  return id.isEmpty ? '$base/profile' : '$base/profile?id=$id';
}

/// The device list the hub keeps: every device that reported, which is how a
/// shared profile knows its peers without naming them.
String hubDevicesUrl(String hubUrl) {
  final base = normalizeHubUrl(hubUrl);
  return base.isEmpty ? '' : '$base/api/devices';
}

bool isHubUrl(String url, String hubUrl) {
  final base = Uri.tryParse(normalizeHubUrl(hubUrl));
  final target = Uri.tryParse(url);
  if (base == null || target == null || base.host.isEmpty) {
    return false;
  }
  return base.scheme == target.scheme &&
      base.host == target.host &&
      base.port == target.port;
}

Map<String, String> hubAuthHeaders(String hubToken) {
  return {'Authorization': 'Bearer ${hubToken.trim()}'};
}

/// A device name or directory id has to be a DNS label a rule can write, and
/// the core refuses the record otherwise.
final _deviceName = RegExp(r'^[A-Za-z0-9._-]{1,63}$');

/// One device the hub knows, as the shared mesh block needs it: the name a
/// rule reaches it by and the id the directory is asked about.
class HubDevice {
  const HubDevice({required this.name, required this.id, this.port = 0});

  final String name;
  final String id;

  /// The port the device serves on, or zero when the hub recorded none.
  final int port;
}

/// Reads the device list out of what the hub answered, in the shape the core
/// expands: the name is the alias someone set, else the host name the machine
/// reported, else the id - the order the hub itself resolves a lookup in. The
/// list is ordered by id so every device of the mesh expands the same peers in
/// the same order, and a name the core would refuse is replaced by the id.
List<HubDevice> parseHubDevices(Object? payload) {
  final nodes = payload is Map ? payload['nodes'] : null;
  if (nodes is! List) {
    return const [];
  }
  final devices = <HubDevice>[];
  final seen = <String>{};
  for (final node in nodes) {
    if (node is! Map) {
      continue;
    }
    final id = '${node['id'] ?? ''}'.trim();
    if (!_deviceName.hasMatch(id)) {
      continue;
    }
    var name = '${node['alias'] ?? node['hostname'] ?? ''}'.trim();
    if (!_deviceName.hasMatch(name) || seen.contains(name)) {
      name = id;
    }
    if (seen.contains(name)) {
      continue;
    }
    seen.add(name);
    final port = node['port'];
    devices.add(
      HubDevice(
        name: name,
        id: id,
        port: port is int && port >= 1 && port <= 65535 ? port : 0,
      ),
    );
  }
  devices.sort((a, b) => a.id.compareTo(b.id));
  return devices;
}

/// Writes the device list into the mesh block together with the flag the core
/// expands from: the block is resolved, so the core takes these devices as
/// they stand and reads nothing while it parses. The parse happens before the
/// tunnel is up, so a device whose network cannot reach the hub directly still
/// starts; [directoryProxy] is the proxy the runtime's own directory requests
/// go through instead of the direct connection that network blocks.
void applyHubDevices(
  Map<String, dynamic> rawConfig, {
  required List<HubDevice> devices,
  String directoryProxy = '',
}) {
  final mesh = rawConfig['mesh'];
  if (mesh is! Map) {
    return;
  }
  mesh['directory-resolved'] = true;
  mesh['devices'] = [
    for (final device in devices)
      {
        'name': device.name,
        'id': device.id,
        if (device.port > 0) 'port': device.port,
      },
  ];
  if (directoryProxy.isNotEmpty) {
    mesh['directory-proxy'] = directoryProxy;
  }
}

void applyHubConnection(
  Map<String, dynamic> rawConfig,
  String hubUrl,
  String hubToken,
) {
  if (!isHubEnabled(hubUrl, hubToken)) {
    return;
  }
  final mesh = rawConfig['mesh'];
  if (mesh is! Map) {
    return;
  }
  mesh['directory-url'] = normalizeHubUrl(hubUrl);
  mesh['directory-token'] = hubToken.trim();
}
