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
