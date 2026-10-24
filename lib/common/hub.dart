/// The Hub hands each device its own profile; both halves name it.
bool isHubEnabled(String hubUrl, String hubToken) {
  return hubUrl.trim().isNotEmpty && hubToken.trim().isNotEmpty;
}

/// The parameter a Hub link carries its token in.
const _hubTokenParam = 'token';

/// Splits a Hub link into the address and the token it carries.
///
/// A link is what a user is given: one value naming the Hub and the credential
/// together, so there is no second field to fall out of step with the first
/// (a stored token and a token inside the profile are two places, and a
/// re-generated one silently desynchronises them). The returned address has the
/// parameter removed, because the core appends its own path to it
/// (`<url>/report`, `<url>/lookup`) and a query in the middle would corrupt
/// those. The token travels in the request header as before.
///
/// A bare address with a separately configured token keeps working: when the
/// link carries no token the one passed in is used unchanged.
({String url, String token}) splitHubLink(String link, {String fallbackToken = ''}) {
  final raw = link.trim();
  if (raw.isEmpty) {
    return (url: '', token: fallbackToken.trim());
  }
  final uri = Uri.tryParse(raw);
  if (uri == null || !uri.hasScheme) {
    return (url: raw, token: fallbackToken.trim());
  }
  final carried = uri.queryParameters[_hubTokenParam]?.trim() ?? '';
  if (carried.isEmpty) {
    return (url: raw, token: fallbackToken.trim());
  }
  final remaining = Map<String, String>.from(uri.queryParameters)
    ..remove(_hubTokenParam);
  // An empty parameter map leaves a bare '?', and passing null would mean
  // "keep the query as it is" — which is the token itself — so the leftover
  // separator is trimmed off instead.
  var stripped = uri.replace(queryParameters: remaining).toString();
  if (stripped.endsWith('?')) {
    stripped = stripped.substring(0, stripped.length - 1);
  }
  return (url: stripped, token: carried);
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

void applyHubConnection(
  Map<String, dynamic> rawConfig,
  String hubUrl,
  String hubToken, {
  bool viaProxy = false,
  String deviceId = '',
}) {
  if (!isHubEnabled(hubUrl, hubToken)) {
    return;
  }
  final mesh = rawConfig['mesh'];
  if (mesh is! Map) {
    return;
  }
  mesh['directory-url'] = normalizeHubUrl(hubUrl);
  // The token is no longer written into the profile. It was the network's
  // shared secret and every device's proof at once, so any device holding it
  // could claim any id. The core now proves its own id with a key it keeps in
  // its own home: registering once, then signing every request. The token the
  // app holds is used for what the app itself fetches, and by nothing else.
  mesh.remove('directory-token');
  // The proxy is the core's own mixed-port inbound, and the core knows its
  // port and credentials - so what is recorded here is the intent, not an
  // address the app would have to keep in step with its own listener.
  if (viaProxy) {
    mesh['directory-via-proxy'] = true;
  }
  // And the core takes its configuration from the hub from now on: it pulls
  // its profile, and the hub knows the whole mesh, so a device that joins
  // appears in this one's list on the next pull instead of never. The pull is
  // signed with the device's own key - no token travels in this block, and
  // none is written into the profile the hub hands back.
  final identity = deviceId.trim().isNotEmpty
      ? deviceId.trim()
      : (mesh['directory-id'] is String ? (mesh['directory-id'] as String).trim() : '');
  if (identity.isNotEmpty) {
    rawConfig['hub'] = <String, dynamic>{
      'url': normalizeHubUrl(hubUrl),
      'id': identity,
      'poll-seconds': 30,
      'keep': <String, dynamic>{'mesh.directory-id': identity},
    };
  }
}
