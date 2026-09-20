/// Names this device in every peer-directory entry of [rawConfig].
///
/// The directory has to know which node a report belongs to, while one profile
/// is shared by every device, so the name comes from a local setting and is
/// written into the generated config here: `id` for a `peer-directory`
/// outbound, `directory-id` for a peer that carries the directory inline, and
/// `directory-id` on the mesh block, whose per-device outbounds the core
/// builds after this point.
void applyDirectoryId(Map<String, dynamic> rawConfig, String id) {
  final trimmed = id.trim();
  if (trimmed.isEmpty) {
    return;
  }
  final mesh = rawConfig['mesh'];
  if (mesh is Map) {
    mesh['directory-id'] = trimmed;
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
      case 'tailnet-peer':
        if (proxy['directory-url'] != null) {
          proxy['directory-id'] = trimmed;
        }
    }
  }
}
