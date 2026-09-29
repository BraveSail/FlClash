/// Names this device to the directory outbounds a profile may still carry by
/// hand: `peer-directory` reports under it and `tailnet-peer` asks for peers
/// with it. The mesh block takes no part in this - the app expands one into
/// plain outbounds and never writes it back.
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
