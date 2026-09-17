/// Points every `peer-directory` entry in [rawConfig] at the name this device
/// uses in the directory.
///
/// The directory has to know which node a report belongs to, while one profile
/// is shared by every device, so the name comes from a local setting and is
/// written into the generated config here.
void applyDirectoryId(Map<String, dynamic> rawConfig, String id) {
  final trimmed = id.trim();
  if (trimmed.isEmpty) {
    return;
  }
  final proxies = rawConfig['proxies'];
  if (proxies is! List) {
    return;
  }
  for (final proxy in proxies) {
    if (proxy is Map && proxy['type'] == 'peer-directory') {
      proxy['id'] = trimmed;
    }
  }
}
