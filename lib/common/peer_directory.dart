void applyDirectoryId(
  Map<String, dynamic> rawConfig,
  String id, {
  String name = '',
  String os = '',
}) {
  final trimmed = id.trim();
  if (trimmed.isEmpty) {
    return;
  }
  final deviceName = name.trim();
  final deviceOs = os.trim();
  final mesh = rawConfig['mesh'];
  if (mesh is Map) {
    mesh['directory-id'] = trimmed;
    if (deviceName.isNotEmpty) {
      mesh['device-name'] = deviceName;
    }
    if (deviceOs.isNotEmpty) {
      mesh['device-os'] = deviceOs;
    }
  }
  final proxies = rawConfig['proxies'];
  if (proxies is! List) {
    return;
  }
  for (final proxy in proxies) {
    if (proxy is! Map) {
      continue;
    }
    switch (proxy['type']) {
      case 'peer-directory':
        proxy['id'] = trimmed;
        _applyDeviceIdentity(proxy, deviceName, deviceOs);
      case 'tailnet-peer':
        if (proxy['directory-url'] != null) {
          proxy['directory-id'] = trimmed;
          _applyDeviceIdentity(proxy, deviceName, deviceOs);
        }
    }
  }
}

void _applyDeviceIdentity(Map proxy, String name, String os) {
  if (name.isNotEmpty) {
    proxy['hostname'] = name;
  }
  if (os.isNotEmpty) {
    proxy['os'] = os;
  }
}
