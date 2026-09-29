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

/// Where the hub answers what the mesh of one device looks like: the devices
/// that belong to it, the user they speak as, and the key pair they encrypt
/// with. [deviceId] is the device asking, which is what tells this one's own
/// entry from its peers'.
String hubMeshUrl(String hubUrl, String deviceId) {
  final base = normalizeHubUrl(hubUrl);
  if (base.isEmpty) {
    return '';
  }
  final id = deviceId.trim();
  return id.isEmpty ? '' : '$base/api/mesh?id=$id';
}

/// The socket a device holds to hear its own profile the moment the dashboard
/// saves one, instead of waiting for its next poll. It names the revision it
/// already runs, so the hub answers with nothing while it is up to date.
String hubProfileWatchUrl(String hubUrl, String deviceId, String etag) {
  final base = normalizeHubUrl(hubUrl);
  if (base.isEmpty) {
    return '';
  }
  final id = deviceId.trim();
  if (id.isEmpty) {
    return '';
  }
  final query = Uri(queryParameters: {
    'id': id,
    if (etag.trim().isNotEmpty) 'etag': etag.trim(),
  }).query;
  return '$base/profile/watch?$query';
}

/// The scheme a socket to this hub is opened with: the hub may be plain http
/// on a LAN, and the socket has to match what the client already reaches.
String hubSocketUrl(String url) {
  if (url.startsWith('https://')) {
    return 'wss://${url.substring('https://'.length)}';
  }
  if (url.startsWith('http://')) {
    return 'ws://${url.substring('http://'.length)}';
  }
  return url;
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
